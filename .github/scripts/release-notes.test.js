const assert = require('node:assert/strict');
const { test } = require('node:test');
const updateRelease = require('./release-notes.js');

async function render({ prBody = '', releaseBody = '', prerelease = false, merged = true } = {}) {
  const updates = [];
  const context = { repo: { owner: 'pydantic', repo: 'monty-helm-chart' }, sha: 'test-commit' };
  const github = {
    rest: {
      repos: {
        getReleaseByTag: async ({ tag }) => {
          assert.equal(tag, 'monty-0.1.0');
          return { data: { id: 1, body: releaseBody } };
        },
        updateRelease: async (data) => updates.push(data),
        listPullRequestsAssociatedWithCommit: async () => ({
          data: [{ number: 2, merged_at: merged ? '2026-01-01' : null, base: { ref: 'main' } }],
        }),
      },
      pulls: {
        get: async () => ({ data: { body: prBody, html_url: 'https://github.com/pydantic/monty-helm-chart/pull/2' } }),
      },
    },
  };
  process.env.RELEASE_TAG = 'monty-0.1.0';
  process.env.IS_PRERELEASE = String(prerelease);
  await updateRelease({ github, context, core: { info() {} } });
  return updates;
}

test('curates the Logfire PR sections and preserves generated notes', async () => {
  const updates = await render({
    prBody: '## Summary\r\n<!-- template -->\r\nAdd storage.\r\n\r\n## Upgrade notes\r\nUpdate values.\r\n### Breaking changes\r\nRemove old keys.\r\n## Testing\r\nNot release notes.',
    releaseBody: 'Generated notes',
  });
  assert.equal(updates.length, 1);
  assert.equal(updates[0].body, [
    '<!-- BEGIN PR NOTES -->',
    '## Summary\n\nAdd storage.',
    '\n## Upgrade notes\n\nUpdate values.\n### Breaking changes\nRemove old keys.',
    '\nPR: https://github.com/pydantic/monty-helm-chart/pull/2',
    '<!-- END PR NOTES -->',
    '\n---\n\nGenerated notes',
  ].join('\n'));
});

test('replaces existing curated notes without interpreting replacement patterns', async () => {
  const [first] = await render({ prBody: '## Summary\nOriginal.', releaseBody: 'Generated notes' });
  const [second] = await render({ prBody: '## Summary\nKeep $& literally.', releaseBody: first.body });
  assert.equal((second.body.match(/BEGIN PR NOTES/g) || []).length, 1);
  assert.ok(second.body.includes('Keep $& literally.'));
  assert.ok(!second.body.includes('Original.'));
  assert.ok(second.body.endsWith('Generated notes'));
});

test('supports Logfire legacy Breaking changes sections', async () => {
  const [update] = await render({ prBody: '## Breaking changes\nMigrate storage.' });
  assert.ok(update.body.includes('## Upgrade notes\n\n### Breaking changes\nMigrate storage.'));
});

test('marks prereleases even without a merged PR', async () => {
  const updates = await render({ prerelease: true, merged: false });
  assert.deepEqual(updates, [{
    owner: 'pydantic', repo: 'monty-helm-chart', release_id: 1, prerelease: true, make_latest: 'false',
  }]);
});

test('does not overwrite notes for empty or unmerged PRs', async () => {
  assert.deepEqual(await render({ prBody: '<!-- no release notes -->' }), []);
  assert.deepEqual(await render({ prBody: '## Summary\nNot merged.', merged: false }), []);
});
