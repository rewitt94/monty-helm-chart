// Keep the release-note sections and markers aligned with logfire-helm-chart.
module.exports = async ({ github, context, core }) => {
  const { owner, repo } = context.repo;
  const tag = process.env.RELEASE_TAG;
  const { data: release } = await github.rest.repos.getReleaseByTag({ owner, repo, tag });

  if (process.env.IS_PRERELEASE === 'true') {
    await github.rest.repos.updateRelease({
      owner, repo, release_id: release.id, prerelease: true, make_latest: 'false',
    });
  }

  const { data: prs } = await github.rest.repos.listPullRequestsAssociatedWithCommit({
    owner, repo, commit_sha: context.sha, per_page: 50,
  });
  const pr = prs.find((candidate) => candidate.merged_at && candidate.base?.ref === 'main');
  if (!pr) {
    core.info(`No merged PR associated with commit ${context.sha}; keeping generated release notes.`);
    return;
  }

  const { data: fullPr } = await github.rest.pulls.get({ owner, repo, pull_number: pr.number });
  const prBody = (fullPr.body || '').replace(/\r\n?/g, '\n').trim();
  const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const extractSection = (heading) => {
    const pattern = new RegExp(
      `(?:^|\\n)##\\s+${escapeRegExp(heading)}\\s*(?:\\n|$)([\\s\\S]*?)(?=\\n##\\s+|$)`, 'i',
    );
    const match = prBody.match(pattern);
    return match ? match[1].replace(/<!--[\s\S]*?-->/g, '').trim() : '';
  };

  const summary = extractSection('Summary');
  let upgradeNotes = extractSection('Upgrade notes');
  const breakingChangesLegacy = extractSection('Breaking changes');
  if (breakingChangesLegacy) {
    upgradeNotes = [upgradeNotes, `### Breaking changes\n${breakingChangesLegacy}`].filter(Boolean).join('\n\n');
  }
  if (!summary && !upgradeNotes) {
    core.info(`PR #${pr.number} does not contain release note sections; keeping generated release notes.`);
    return;
  }

  const curated = [];
  if (summary) curated.push('## Summary', summary);
  if (upgradeNotes) curated.push('## Upgrade notes', upgradeNotes);
  curated.push(`PR: ${fullPr.html_url}`);

  const markerStart = '<!-- BEGIN PR NOTES -->';
  const markerEnd = '<!-- END PR NOTES -->';
  const curatedBlock = `${markerStart}\n${curated.join('\n\n')}\n${markerEnd}`;
  const existingBody = (release.body || '').trim();
  const body = existingBody.includes(markerStart) && existingBody.includes(markerEnd)
    ? existingBody.replace(new RegExp(`${markerStart}[\\s\\S]*?${markerEnd}`), () => curatedBlock)
    : [curatedBlock, existingBody].filter(Boolean).join('\n\n---\n\n');

  await github.rest.repos.updateRelease({ owner, repo, release_id: release.id, body });
};
