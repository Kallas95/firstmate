#!/usr/bin/env node
// Semantic policy for the worker command guard: may an autonomous firstmate
// worker run this shell command, or touch this file path?
//
// THIS FILE IS THE SINGLE OWNER OF THE WORKER PERIMETER. Every application
// point - the Pi per-task extension and the Claude per-task PreToolUse hook,
// both written by bin/fm-spawn.sh - calls bin/fm-worker-pretool-check.sh, which
// calls this module. No application point restates a rule, so no two harnesses
// can drift apart: extending the perimeter means editing PERIMETER below and
// nothing else. See docs/worker-command-guard.md for the complete contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, expands, sources, or runs any byte of the submitted command;
// it inspects lexical command positions only.
//
// Deliberate boundary: this policy classifies the command a worker submits, not
// the body of a script that command would run. Re-classifying arbitrary script
// bodies blocks this repo's own test suite (which legitimately chmods fixtures)
// and any project's build scripts, so a worker's own scripts stay out of scope.

import { Lexer, splitProgram, commandPosition, SHELL_RESERVED_WORDS } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  "privilege-escalation":
    "sudo is forbidden for a firstmate worker: a task worktree never needs host privileges, and an escalated command escapes every isolation the task relies on.",
  "remote-transfer":
    "ssh, scp, and rsync are forbidden for a firstmate worker: they reach hosts and move data outside the task worktree. Ask firstmate if the task genuinely needs a remote host.",
  "permission-change":
    "chmod is forbidden for a firstmate worker: file modes outside the task's own new files are host state, not task output.",
  "global-git-config":
    "git config --global is forbidden for a firstmate worker: it mutates the captain's host-wide git configuration. Use repository-local git config instead.",
  "history-rewrite":
    "git rebase is forbidden for a firstmate worker: it rewrites history the delivery path depends on. Land work with ordinary commits and let the delivery path reconcile.",
  "protected-branch-push":
    "pushing to master/main is forbidden for a firstmate worker: work lands through a PR. Push the task branch instead, for example git push origin HEAD.",
  "dotenv-access":
    "reading a .env file, or copying one elsewhere, is forbidden for a firstmate worker: it holds live credentials. Ask firstmate if the task genuinely needs a secret.",
  "unclassifiable-perimeter-command":
    "unsupported or malformed shell syntax mentions a command inside the worker perimeter, so it cannot be classified and is refused rather than allowed.",
};

// Commands denied outright, keyed by the reason they earn. Matched on the
// executed command word's basename, so /usr/bin/ssh is the same denial as ssh.
const DENIED_COMMANDS = new Map([
  ["ssh", "remote-transfer"],
  ["scp", "remote-transfer"],
  ["rsync", "remote-transfer"],
  ["chmod", "permission-change"],
]);

// Commands that read file contents. Denied only when an argument names a .env.
const READING_COMMANDS = new Set([
  "cat", "less", "more", "tail", "head", "strings", "od", "xxd", "base64",
  "nl", "tac", "bat", "sed", "awk", "grep", "egrep", "fgrep", "rg", "cut", "sort",
]);

// Commands that copy or relocate a file. Denied when a .env is a SOURCE.
const COPYING_COMMANDS = new Set(["cp", "mv", "install", "ln", "tee", "rsync", "scp"]);

// Options that move a copy's destination out of the trailing operand, so every
// remaining operand is a source: `cp -t /tmp .env` copies the secret out too.
// A short target-directory option carries its value attached to the cluster
// (`-t/tmp`, `-rt/tmp`) or in the next token (`-t /tmp`, `-rt /tmp`), and it may
// sit anywhere inside a cluster, so all of those spellings are recognized: a
// spelling read as an ordinary flag would put the destination back on the
// trailing operand and let a secret out as a source.
const TARGET_DIRECTORY_SHORT = /^-[A-Za-z]*?t(.*)$/;
const TARGET_DIRECTORY_LONG = /^--target-directory(?:=(.*))?$/;

// Redirections that make the shell READ the named file. `> .env` and `>> .env`
// write a file and expose nothing; `<<` and `<<<` name a delimiter or a string
// rather than a path.
const READING_REDIRECTIONS = new Set(["<", "<>"]);

// Harness file tools that only WRITE at the path they name. Every other tool is
// treated as a reader, so an unknown tool name still fails closed.
const PATH_WRITING_TOOLS = new Set(["write", "edit", "multiedit", "notebookedit"]);

// Shells whose -c payload is another program this policy must classify too.
const SHELLS = new Set(["sh", "bash", "zsh", "ksh", "dash"]);

// Raw-text markers for the fail-closed unclassifiable path: when the tokenizer
// cannot parse a command that mentions one of these, refusing beats guessing.
// Anchored on word boundaries so an ordinary word that merely CONTAINS one -
// "legitimate", "digits", a github URL - is not mistaken for the command, which
// would refuse work this guard has no opinion about.
// COUPLED to the rules above - a new perimeter command needs a marker here.
const PERIMETER_MARKERS = /(?:^|[^\w-])(?:sudo|ssh|scp|rsync|chmod|git)(?![\w-])|\.env(?![\w.-])/;

const MAX_DEPTH = 6;

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

const ALLOW = { decision: "allow" };

function basename(value) {
  const cleaned = String(value).replace(/^@/, "").replace(/\\/g, "/").replace(/\/+$/, "");
  return cleaned.split("/").filter(Boolean).at(-1) || cleaned;
}

// A path is inside the perimeter when its own name is exactly .env. Deliberately
// narrower than "anything containing env": firstmate itself tracks ordinary
// files such as config/x-mode.env that workers legitimately read.
function isDotenvPath(value) {
  return basename(value) === ".env";
}

function isOption(value) {
  return value.startsWith("-");
}

// The operands a copy or move READS. The perimeter covers exposing a secret,
// not creating a file: `cp .env.example .env` writes a fresh local config and
// exposes nothing, while `cp .env /tmp/x` and `mv .env /tmp/x` carry the secret
// out. The destination is the trailing operand unless an explicit
// target-directory option holds it, in which case every operand is a source.
function copySourceOperands(args) {
  const operands = [];
  let destinationIsTrailing = true;
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    const isLong = value.startsWith("--");
    const target = isLong
      ? TARGET_DIRECTORY_LONG.exec(value)
      : (isOption(value) ? TARGET_DIRECTORY_SHORT.exec(value) : null);
    if (target) {
      destinationIsTrailing = false;
      if (isLong ? target[1] === undefined : !target[1]) index += 1;
      continue;
    }
    if (isOption(value)) continue;
    operands.push(value);
  }
  return destinationIsTrailing ? operands.slice(0, -1) : operands;
}

// A harness file tool that only writes at the path it names exposes no secret,
// so the path perimeter follows the same source/destination line as the shell
// rules. An absent or unknown tool name is treated as a read.
function pathToolReads(tool) {
  return !PATH_WRITING_TOOLS.has(String(tool).trim().toLowerCase());
}

// git's own options before the subcommand. -C/-c and the long forms take a
// value; everything else here is a bare flag.
function gitSubcommandIndex(words, start) {
  let index = start;
  while (words[index]) {
    const value = words[index].value;
    if (!isOption(value)) return index;
    if (value === "-C" || value === "-c" || value === "--git-dir" || value === "--work-tree" || value === "--namespace" || value === "--exec-path") {
      index += 2;
      continue;
    }
    index += 1;
  }
  return index;
}

// The destination of a push argument: `+HEAD:main` and `refs/heads/main` both
// resolve to main, while `HEAD` and `fm/task-branch` do not.
function pushDestination(value) {
  const refspec = value.replace(/^\+/, "");
  const destination = refspec.includes(":") ? refspec.slice(refspec.lastIndexOf(":") + 1) : refspec;
  return destination.replace(/^refs\/heads\//, "");
}

function classifyGit(position) {
  const index = gitSubcommandIndex(position.words, position.index + 1);
  const subcommand = position.words[index]?.value;
  if (!subcommand) return ALLOW;
  const rest = position.words.slice(index + 1).map((word) => word.value);
  if (subcommand === "rebase") return deny("history-rewrite");
  if (subcommand === "config" && rest.some((value) => value === "--global" || value.startsWith("--global="))) {
    return deny("global-git-config");
  }
  if (subcommand === "push") {
    for (const value of rest) {
      if (isOption(value)) continue;
      const destination = pushDestination(value);
      if (destination === "master" || destination === "main") return deny("protected-branch-push");
    }
  }
  return ALLOW;
}

// A redirection target is skipped by commandPosition's word list, so `cat < .env`
// must be read off the raw node tokens. Only an input redirection reads the
// file; `echo x > .env` creates one, which the perimeter does not cover.
function redirectionReadsDotenv(tokens) {
  let pendingTarget = false;
  for (const token of tokens) {
    if (token.type === "redir") {
      pendingTarget = !token.inlineTarget && READING_REDIRECTIONS.has(token.value);
      continue;
    }
    if (pendingTarget && token.type === "word") {
      pendingTarget = false;
      if (isDotenvPath(token.value)) return true;
    }
  }
  return false;
}

// A compound command's body arrives as a node introduced by the reserved word
// that opened it - `do chmod +x $f`, `then git push origin main`, `time chmod
// +x a`. commandPosition would read that keyword as the executed command and
// never reach the body, so the keywords are dropped and the remainder is
// classified exactly like the same command written on its own. `!` leads the
// same way, negating the command that follows it rather than being one.
function withoutLeadingKeywords(tokens) {
  let start = 0;
  while (tokens[start]?.type === "word") {
    const value = tokens[start].value;
    if (value !== "!" && !SHELL_RESERVED_WORDS.has(basename(value))) break;
    start += 1;
  }
  return start === 0 ? tokens : tokens.slice(start);
}

// The payload of `sh -c '<program>'`, or "" when this is not such an invocation.
function shellPayload(position) {
  const words = position.words;
  for (let index = position.index + 1; index < words.length; index += 1) {
    if (/^-[a-zA-Z]*c$/.test(words[index].value)) return words[index + 1]?.value ?? "";
  }
  return "";
}

function classifyCommand(command, depth) {
  // Nesting deeper than this is not classified, so it is refused on the same
  // terms as unparseable syntax rather than allowed: a perimeter command buried
  // under seven layers of substitution must not fall out of the perimeter.
  if (depth > MAX_DEPTH) {
    return PERIMETER_MARKERS.test(command) ? deny("unclassifiable-perimeter-command") : ALLOW;
  }
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) {
    // Fail closed only where it matters: unparseable syntax that mentions a
    // perimeter command is refused, while unrelated exotic syntax stays allowed
    // so the guard never blocks ordinary work it has no opinion about.
    return PERIMETER_MARKERS.test(command) ? deny("unclassifiable-perimeter-command") : ALLOW;
  }

  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) {
    // Every stage of every list matters: a pipeline stage or a backgrounded
    // node runs the command just as surely as a top-level one.
    if (redirectionReadsDotenv(node)) return deny("dotenv-access");

    const position = commandPosition(withoutLeadingKeywords(node));

    // A nested program runs whatever it contains, so every place the shared
    // lexer parks one is classified against the same perimeter: subshells and
    // brace groups, the command substitutions, backticks, and process
    // substitutions it stores on a word's `subs`, and the payload a wrapper
    // carries inline such as `env -S '<program>'`. Without this descent, a
    // plain `$(...)` would carry the whole perimeter straight through.
    for (const payload of position.wrapperPayloads) {
      const nested = classifyCommand(payload, depth + 1);
      if (nested.decision === "deny") return nested;
    }
    for (const token of node) {
      if (token.type === "group") {
        const nested = classifyCommand(token.content, depth + 1);
        if (nested.decision === "deny") return nested;
      }
      if (token.type === "word") {
        for (const substitution of token.subs) {
          const nested = classifyCommand(substitution.content, depth + 1);
          if (nested.decision === "deny") return nested;
        }
      }
    }

    if (position.wrappers.includes("sudo")) return deny("privilege-escalation");
    if (!position.command) {
      // A wrapper option the shared classifier could not resolve can hide the
      // real command position, so a node that mentions the perimeter and
      // resolves to no command is refused rather than skipped.
      if (position.unresolvedWrapperOption && position.words.some((word) => PERIMETER_MARKERS.test(word.value))) {
        return deny("unclassifiable-perimeter-command");
      }
      continue;
    }

    const name = basename(position.command.value);
    const denied = DENIED_COMMANDS.get(name);
    if (denied) return deny(denied);

    const args = position.words.slice(position.index + 1).map((word) => word.value);
    if (READING_COMMANDS.has(name) && args.some(isDotenvPath)) return deny("dotenv-access");
    if (COPYING_COMMANDS.has(name) && copySourceOperands(args).some(isDotenvPath)) {
      return deny("dotenv-access");
    }

    if (name === "git") {
      const gitDecision = classifyGit(position);
      if (gitDecision.decision === "deny") return gitDecision;
    }

    if (SHELLS.has(name)) {
      const payload = shellPayload(position);
      if (payload) {
        const nested = classifyCommand(payload, depth + 1);
        if (nested.decision === "deny") return nested;
      }
    }
  }
  return ALLOW;
}

// The single entry point. A tool call carries a command, a path, or both, plus
// the harness's own tool name when it has one; each is classified against the
// same perimeter regardless of which harness delivered it. The tool name is
// data, never a rule: this owner alone decides what it means.
function decision({ command = "", path = "", tool = "" } = {}) {
  if (path && isDotenvPath(path) && pathToolReads(tool)) return deny("dotenv-access");
  if (command) return classifyCommand(command, 0);
  return ALLOW;
}

const OPTIONS = ["command", "path", "tool"];

function parseArguments(argv) {
  const result = { command: "", path: "", tool: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    const option = OPTIONS.find((key) => name === `--${key}` || name.startsWith(`--${key}=`));
    if (!option) throw new Error(`unknown argument: ${name}`);
    if (name.startsWith(`--${option}=`)) {
      result[option] = name.slice(option.length + 3);
      continue;
    }
    if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
    result[option] = argv[i + 1];
    i += 1;
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    const result = decision(args);
    if (result.decision === "allow") {
      process.stdout.write("allow\n");
    } else {
      process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
