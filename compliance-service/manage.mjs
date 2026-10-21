// Operator-only local queue management. There is deliberately no web admin API.
import { readFile, readdir, writeFile, rename } from 'node:fs/promises';
import { join, resolve } from 'node:path';

const [directory, action, id, confirmation] = process.argv.slice(2);
if (!directory || !['list', 'complete-deletion', 'resolve-report'].includes(action)) {
  console.error('Usage: node manage.mjs PRIVATE_STATE_DIRECTORY list|complete-deletion|resolve-report [RECEIPT_ID] [--confirm-erasure]'); process.exit(1);
}
const root = resolve(directory);
if (action === 'list') {
  for (const name of await readdir(root)) {
    if (!/^[a-f0-9]{64}\.json$/.test(name)) continue;
    const record = JSON.parse(await readFile(join(root, name), 'utf8'));
    console.log(JSON.stringify(record));
  }
} else {
  if (!/^[a-f0-9]{64}$/.test(id ?? '')) throw new Error('Invalid receipt');
  const path = join(root, `${id}.json`), record = JSON.parse(await readFile(path, 'utf8'));
  if (action === 'complete-deletion') {
    if (record.kind !== 'deletion' || confirmation !== '--confirm-erasure') throw new Error('Verify remote account, files, history, tool data and sessions are erased first; then pass --confirm-erasure');
    // This command records verified completion; it does NOT erase an xbot DB.
    delete record.username; record.status = 'deleted';
  } else {
    if (record.kind !== 'report') throw new Error('Not a report');
    delete record.content; delete record.detail; record.status = 'resolved';
  }
  record.completed = new Date().toISOString();
  await writeFile(path + '.tmp', JSON.stringify(record), { mode: 0o600 }); await rename(path + '.tmp', path);
  console.log(JSON.stringify({ id: record.id, status: record.status }));
}
