#!/usr/bin/env node
import {
  Lexer,
  commandPosition,
  evalPayload,
  shellHeredocPayloads,
  shellHereStringPayloads,
  shellInvocation,
  splitProgram,
} from "./fm-arm-command-policy.mjs";

const TRAEX_NAMES = new Set(["traex", "traecli"]);
const RESERVED = new Set([
  "if", "then", "else", "elif", "fi", "for", "while", "until", "case", "esac",
  "do", "done", "function", "select", "time", "coproc",
]);

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function merge(left, right) {
  if (left === "traex" || right === "traex") return "traex";
  if (left === "unresolved" || right === "unresolved") return "unresolved";
  return "other";
}

function commandQuery(position) {
  const prefix = position.words.slice(position.prefixAssignments, position.index);
  let command = false;
  for (const word of prefix) {
    const value = word.value;
    if (!command) {
      if (basename(value) === "command") command = true;
      continue;
    }
    if (value === "--") return false;
    if (/^-[^-]*[vV]/.test(value) || value === "--help" || value === "--version") return true;
    if (!value.startsWith("-") || value === "-") return false;
  }
  return false;
}

function classify(command, depth = 0) {
  if (depth > 12) return "unresolved";
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return "unresolved";
  const program = splitProgram(lexed.tokens);
  let result = "other";

  for (const tokens of program.nodes) {
    const position = commandPosition(tokens);
    if (position.unresolvedWrapperOption) result = merge(result, "unresolved");
    if (RESERVED.has(basename(position.words[0]?.value || ""))) result = merge(result, "unresolved");

    for (const payload of position.wrapperPayloads) {
      result = merge(result, classify(payload, depth + 1));
    }
    for (const token of tokens) {
      if (token.type === "group") result = merge(result, classify(token.content, depth + 1));
      if (token.type !== "word") continue;
      for (const substitution of token.subs) {
        result = merge(result, classify(substitution.content, depth + 1));
      }
    }

    const shell = shellInvocation(position);
    if (shell?.kind === "command") {
      if (!shell.payload || !shell.payload.literal || shell.payload.subs.length > 0) {
        result = merge(result, "unresolved");
      } else {
        result = merge(result, classify(shell.payload.value, depth + 1));
      }
    } else if (shell?.kind === "stdin") {
      for (const payload of [...shellHeredocPayloads(tokens, position), ...shellHereStringPayloads(tokens, position)]) {
        result = merge(result, classify(payload, depth + 1));
      }
    }

    const evaluated = evalPayload(position);
    if (basename(position.command?.value || "") === "eval") {
      result = merge(result, evaluated === null ? "unresolved" : classify(evaluated, depth + 1));
    }

    if (!position.command || commandQuery(position)) continue;
    if (!position.command.literal || position.command.subs.length > 0) {
      result = merge(result, "unresolved");
    } else if (TRAEX_NAMES.has(basename(position.command.value))) {
      result = "traex";
    }
  }
  return result;
}

let command = null;
for (let index = 2; index < process.argv.length; index += 1) {
  if (process.argv[index] !== "--command" || index + 1 >= process.argv.length || command !== null) {
    process.stderr.write("usage: fm-traex-raw-command-policy.mjs --command <command>\n");
    process.exit(2);
  }
  command = process.argv[index + 1];
  index += 1;
}
if (command === null) {
  process.stderr.write("usage: fm-traex-raw-command-policy.mjs --command <command>\n");
  process.exit(2);
}
process.stdout.write(`${classify(command)}\n`);
