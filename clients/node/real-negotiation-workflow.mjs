// Concept
//
// Both independent clients negotiate against a real server, not a scripted
// peer: they refuse session traffic locally before verified initialization,
// keep refusing it after the server refuses an old-only offer, and accept only
// the exact pinned generation and digest.
//
// Technical depth
//
// Usage:
//   node real-negotiation-workflow.mjs --daemon <socket-path>
//   node real-negotiation-workflow.mjs <elixir-executable> <path>...
//
// Each scenario uses a fresh connection. The summary line names only what the
// client observed. Any unexpected outcome ends non-zero.

import { Connection, wire } from "./loopex-client.mjs";
import { DaemonConnection } from "./daemon-client.mjs";
import { CURRENT_CONTRACTS } from "./contract-manifest.mjs";

const [target, ...rest] = process.argv.slice(2);
if (!target || (target === "--daemon" ? rest.length !== 1 : rest.length === 0)) {
  process.stderr.write("usage: node real-negotiation-workflow.mjs (--daemon <socket> | <elixir> <path>...)\n");
  process.exit(2);
}
const daemon = target === "--daemon";
const contract = daemon ? CURRENT_CONTRACTS.daemon : CURRENT_CONTRACTS.foreground;
const open = async () => (daemon ? await DaemonConnection.open(rest[0]) : foreground(target, rest));
const refusedLocally = async (connection) => {
  try {
    await connection.request("session.create", { command_id: wire.identity("never"), session_options: { version: 1 } });
    return false;
  } catch (error) {
    return /verified initialization/.test(error.message);
  }
};
const finish = async (connection) => {
  connection.close();
  if (!daemon) await connection.ended();
};

const summary = {};

const early = await open();
summary.refused_before_initialize = await refusedLocally(early);
await finish(early);

const old = await open();
const oldOffer = await old.request("initialize", {
  generations: ["loopex.session.v1-experimental", "loopex.experimental/1", "loopex.experimental/2"],
  capabilities: [],
});
summary.old_offer_code = oldOffer.code;
summary.refused_after_old_offer = await refusedLocally(old);
await finish(old);

const current = await open();
const initialized = await current.initialize();
summary.generation = initialized.selected_generation;
summary.digest_matches_pin = initialized.exact_schema_sha256 === contract.schemaDigest;
const repeated = await current.request("initialize", { generations: [contract.generation], capabilities: [] });
summary.repeat_code = repeated.code;
await finish(current);

process.stdout.write(JSON.stringify(summary) + "\n");
process.exit(0);

function foreground(elixir, paths) {
  const args = [];
  for (const path of paths) args.push(...(path.endsWith(".exs") ? ["-r", path] : ["-pa", path]));
  args.push("-e", process.env.LOOPEX_WORKFLOW_ENTRY || "Loopex.AppServer.Fixture.serve()");
  return new Connection(elixir, args);
}
