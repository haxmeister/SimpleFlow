# SimpleFlow 0.191 - Independent Adversarial Code Audit

**Audit date:** 2026-10-02  
**Target release:** SimpleFlow 0.191  
**Source snapshot:** `haxmeister/SimpleFlow` commit `b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba`  
**Primary module blob:** `lib/SimpleFlow.pm` SHA `223776f9e29e94651d9767de1b81328253dbb845`  
**Audit branch:** `audit/simpleflow-review-20261002`  
**Verification run:** https://github.com/haxmeister/SimpleFlow/actions/runs/37077375245

## Purpose and scope

This is an independent review of SimpleFlow 0.191 intended for David E. Condon's review. It is not a patch proposal and does not assume that every item below should be fixed exactly as suggested. The goal was to look for correctness failures, data-loss cases, security-sensitive edge cases, process-management bugs, cache invalidation errors, API inconsistencies, portability problems, and failure modes that are unlikely to appear in ordinary happy-path tests.

The audit covered:

- `lib/SimpleFlow.pm`
- the full shipped test suite
- `Changes`
- `README.md` / POD behavior descriptions
- `SECURITY.md`
- distribution/build metadata
- process/signal handling
- output capture and redirection
- failure cleanup
- `stale` / `stale.cmd`
- locking
- retries
- environment handling
- wrappers, containers, conda, and SLURM command construction
- `parallel()`
- trace/report handling
- error paths and cross-feature interactions

I also wrote adversarial regression probes on a separate audit-only branch and ran them in GitHub Actions. The production source was not modified.

## Baseline verification

Before running the adversarial probes, the unchanged upstream test suite was run on Ubuntu 24.04 with Perl 5.40.5.

Result:

- **9 test files**
- **152 tests**
- **all upstream tests passed**

The audit script then exercised 14 targeted edge cases against the same source snapshot. The top-level audit run completed successfully because its assertions describe the current problematic behavior; in other words, a green audit probe means the suspected behavior was reproduced.

One `parallel()` serialization probe intentionally causes a forked child to unwind back through the caller after `Storable::nstore()` fails. That child consequently emitted duplicated Test::Builder output before the parent recovered. That strange output is itself evidence of the bug described in finding 8.

## Executive summary

I found several issues I would recommend reviewing before treating 0.191 as robust in hostile, shared, or highly automated environments.

The most important are:

1. **A local file-clobber path in `stale.cmd` signature writing** through a predictable temporary filename and symlink following.
2. **Destructive failure cleanup** that recursively deletes any pre-existing `<output>.failed` directory without proving SimpleFlow owns it.
3. **A trailing-slash directory-output bug** that can delete data inside the failed output and then fail to move the failed output aside at all.
4. **`SIGCHLD` incompatibility**: a caller that ignores or reaps children can make `task()` report success as failure and can make `parallel()` hang.
5. **`stale.cmd` false cache hits** because the signature does not faithfully encode all execution semantics (`threads`, `stdin`, and argv boundaries are confirmed examples).
6. **Embedded NUL is accepted in argv and environment values**, although the OS execution boundary truncates it; this also creates deterministic `stale.cmd` signature collisions.
7. **Explicit environment values, including secrets, are copied into logs and traces by default.**
8. **A `parallel()` child can escape its intended `_exit()` path** when Storable cannot serialize an otherwise accepted result value.
9. **Caller real-time interval timers are damaged by `timeout`.**
10. **Output capture can turn valid binary subprocess output into a fatal decoding error** depending on the caller's PerlIO layers.

I found no evidence of an unauthenticated remote-code-execution vulnerability in SimpleFlow itself. A string `cmd` is intentionally handed to a shell, and `SECURITY.md` correctly identifies caller-built shell strings as the caller's injection boundary. The findings below are about behavior SimpleFlow itself controls.

---

# Confirmed findings

## 1. HIGH - `stale.cmd` signature writer can follow a predictable symlink and clobber another file

**Status:** Reproduced in CI  
**Area:** `_write_signature()`  
**Source:** `lib/SimpleFlow.pm` around lines 1042-1055

Permanent source link:

https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1042-L1055

### What happens

A successful `stale.cmd` run writes its signature through:

```perl
my $partial = "$file.$$";
open my $fh, '>', $partial or die ...;
print {$fh} "$signature\n";
close $fh or die ...;
rename $partial, $file or die ...;
```

The temporary name is deterministic from:

- the signature-file name, itself deterministic from output paths; and
- the current PID.

The normal Perl `open '>'` follows symbolic links.

In the audit, a symlink was pre-planted at the predictable temporary pathname and pointed at a disposable victim file. A successful SimpleFlow task:

- followed the symlink,
- overwrote the victim with the command signature, and
- renamed the symlink into the final signature pathname.

The CI probe confirmed both effects.

### Security impact

If a SimpleFlow working directory or its `.simpleflow/cmd` directory is writable by another user/process, that party can potentially redirect a signature write into another file writable by the SimpleFlow user.

This is especially relevant to the module's HPC/SLURM use case, where project workspaces are sometimes group-writable.

The content written is constrained (a digest plus newline), so this is not arbitrary-content write, but it is still a **local file-clobber primitive**.

### Recommended fix

Use a secure same-directory temporary file with exclusive creation and no symlink following:

- `File::Temp` in the target directory, or
- `sysopen` with `O_CREAT|O_EXCL` and `O_NOFOLLOW` where available.

Then:

1. write the complete signature,
2. check every write and close,
3. atomically rename into place,
4. verify the internal `.simpleflow` hierarchy is not a symlink or unexpected file type.

Consider making internal state directories private (`0700`) unless sharing them is explicitly required.

### Regression test

Pre-create the expected temporary path as a symlink to a sentinel file. Run a successful `stale.cmd` task. Assert:

- the sentinel file is unchanged;
- the signature is recorded normally;
- the operation either safely chooses another temporary name or rejects the unsafe path.

---

## 2. HIGH - Failure cleanup can recursively delete unrelated `<output>.failed` data

**Status:** Reproduced in CI  
**Area:** `_move_aside()`  
**Source:** lines 395-414

https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L395-L414

### What happens

Before moving a failed output to `<output>.failed`, SimpleFlow unconditionally removes whatever already exists at that name:

```perl
if ((-d $aside) && (not -l $aside)) {
    File::Path::rmtree($aside);
} elsif ((-e $aside) || (-l $aside)) {
    unlink $aside;
}
rename $file, $aside;
```

There is no marker proving that the existing `.failed` object was created by SimpleFlow.

The audit created an unrelated directory named `dataset.failed` containing a sentinel file. A failing task declared `dataset` as its output directory. SimpleFlow recursively deleted the old `dataset.failed` tree and replaced it with the new partial output.

### Impact

This is a direct data-loss hazard. It requires a naming collision, but `.failed` is an ordinary and plausible suffix.

This is intentionally codified by the current tests as "replace the .failed directory of an earlier failure," but the implementation cannot distinguish "earlier SimpleFlow failure" from "unrelated user data."

### Recommended fix

Do not use a destructive fixed sibling name as the quarantine namespace.

Safer models include:

```text
.simpleflow/failed/<task-id>/<attempt>/
```

or:

```text
output.failed.<timestamp>.<pid>.<attempt>
```

If the fixed `.failed` name is retained, never delete an unmarked existing path. Either:

- refuse with a clear error, or
- choose a unique alternate name.

---

## 3. HIGH - Trailing slash on `output.dir` makes failure quarantine delete inside the output, then fail

**Status:** Reproduced in CI  
**Area:** `_normalise_files()` + `_move_aside()`

### Reproduction

Declare:

```perl
'output.dir' => 'made/'
```

If the command creates:

```text
made/.failed/valuable
```

and then fails, `_move_aside()` computes:

```text
file  = made/
aside = made/.failed
```

It recursively deletes `made/.failed`, then tries:

```text
rename made/ -> made/.failed
```

which attempts to move a directory into its own child and fails.

The audit confirmed:

- `made/.failed/valuable` was deleted;
- the failed `made/` directory remained at its declared output name;
- the rename failed.

### Impact

This combines two bad outcomes:

1. data created by the failed command can be destroyed; and
2. the failed declared output remains in place, defeating the very protection `_move_aside()` was introduced to provide.

A subsequent run may therefore see the failed directory as an existing output and skip work.

### Recommended fix

Canonicalize declared paths before deriving sidecar paths. At minimum:

- remove trailing separators except for filesystem roots;
- reject output/sidecar relationships where the sidecar resolves inside the output;
- use a separate internal quarantine directory rather than a sibling suffix.

Add path-overlap validation for all declared outputs.

---

## 4. HIGH - Caller `SIGCHLD` policy can break `task()` and hang `parallel()`

**Status:** Reproduced in CI with `$SIG{CHLD} = 'IGNORE'`  
**Area:** `_run_forked()` and `parallel()`  
**Source:** `waitpid` sites around lines 573-639 and 1776

Relevant source:

https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L507-L642

https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1681-L1792

### What happens

SimpleFlow assumes it will be able to reap the children it forks.

A common Unix daemon pattern is:

```perl
$SIG{CHLD} = 'IGNORE';
```

Perl documents that on many Unix systems this causes children to be automatically reaped and subsequent `wait`/`waitpid` to return `-1`.

With that caller setting:

#### `task()`

A command that actually exits successfully is auto-reaped before SimpleFlow's wait completes. The audit observed:

- `will.do => 'FAILED'`
- `exit => -1`

for a child that executed `exit 0`.

#### `parallel(jobs => 2, ...)`

The parent polls with:

```perl
waitpid($pid, POSIX::WNOHANG()) == $pid
```

An already auto-reaped child returns `-1`, never equals its PID, and remains forever in `%running`.

The audit needed a safety alarm to escape the loop.

### Related risk

A caller-installed `SIGCHLD` handler that calls `waitpid(-1, ...)` can create the same class of interference by reaping SimpleFlow's child before SimpleFlow does. This variant was source-reviewed but not separately exercised in CI.

### Recommended fix

SimpleFlow needs an explicit child-ownership policy.

Options include:

- temporarily block `SIGCHLD` around fork/registration/reap critical sections;
- preserve and restore the caller's handler carefully;
- detect `ECHILD` and provide a deterministic failure rather than looping forever;
- document incompatibility with external child reapers if fully composable behavior is not feasible.

`parallel()` must never keep a PID in `%running` forever after `waitpid` reports that no such child exists.

---

## 5. HIGH - `stale.cmd` can falsely declare changed work current

**Status:** Multiple forms reproduced in CI  
**Area:** `_command_signature()` / `_wrapped_cmd()`  
**Source:** lines 964-1024

https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L964-L1024

The documentation says changing the command, its explicit environment, or what it runs inside causes `cmd.changed` and a rebuild. The signature is intended to represent "everything that decides what the command does, other than its inputs."

Several execution semantics are not encoded faithfully.

### 5A. `threads` is omitted for local execution

`threads` changes the command environment:

```perl
$ENV{SIMPLEFLOW_THREADS} = $r->{threads} if $r->{threads} > 0;
```

but `_command_signature()` hashes only `$r->{env}` plus `wrapped.cmd`.

Audit sequence:

1. run with `threads => 1`, `stale.cmd => 1`;
2. output records `SIMPLEFLOW_THREADS=1`;
3. rerun identical task with `threads => 2`;
4. `cmd.changed` remains `0`;
5. task is skipped;
6. old output remains.

This is a straightforward stale-result bug.

### 5B. `stdin` semantics are omitted

Changing:

```perl
stdin => 'devnull'
```

to:

```perl
stdin => 'inherit'
```

can completely change program output, but the signature does not include `stdin`.

The audit confirmed that a first run reading EOF from `/dev/null` was still considered current after switching to inherited input.

### 5C. Wrapped argv boundaries are lost

The signature includes:

```perl
$r->{'wrapped.cmd'}
```

which is only a display string:

```perl
join(' ', @$run_cmd)
```

Different argument vectors can therefore have identical signature input.

The audit demonstrated:

```perl
wrapper => ['wrap',   'a b']
wrapper => ['wrap a', 'b']
```

Both yield the same `wrapped.cmd` text and the same command signature although they are different exec argument vectors.

This same representation issue can affect executor/container/wrapper arguments containing spaces.

### 5D. Embedded NUL makes deterministic signature collisions

The signature uses NUL as its field separator and comments that NUL "cannot occur" in command words or the environment.

However, input validation does not enforce that for environment **values** or argv words.

The audit demonstrated equal signatures for conceptually different environments:

```perl
{ A => "x\0B=y" }
```

and:

```perl
{ A => "x", B => "y" }
```

### Recommended fix

Build the signature from a structured canonical representation of the **actual execution contract**, not a printable command string.

For example, canonical JSON or explicit length-prefixed fields containing:

- original command type (`string` vs argv);
- exact argv element boundaries;
- exact wrapper/container/executor argv boundaries;
- explicit environment changes;
- synthetic `SIMPLEFLOW_THREADS`;
- `stdin` mode;
- container/conda/executor semantics that affect execution;
- any other option whose change can alter output.

Reject embedded NUL before the execution boundary.

Using SHA-256 instead of MD5 would also be sensible, but fixing the representation ambiguity is more important than changing the hash algorithm.

---

## 6. MEDIUM - Embedded NUL is accepted in argv/environment but the OS execution boundary truncates it

**Status:** Reproduced in CI  
**Areas:** command validation and `env` validation

### Environment values

Environment **names** reject NUL, but values only reject references:

```perl
my @bad_names  = grep { ($_ eq '') || /[=\0]/ } ...;
my @bad_values = grep { ref $args->{env}{$_} ne '' } ...;
```

A value such as:

```perl
"A\0B"
```

is accepted.

On the tested POSIX system, the child received only the portion before NUL.

### Array command words

Array-form `cmd` validates that elements are defined but does not reject NUL.

The audit passed `"a\0b"` as one argument. The child observed an argument length of `1`.

### Impact

The record, logging, cache signature, and caller's understanding can describe one value while the executed program receives another.

This is a classic boundary-validation problem and also contributes to finding 5D.

### Recommended fix

Reject `\0` in every string that crosses a C-string interface:

- array `cmd` elements;
- wrapper words;
- executor args;
- container args;
- environment names and values;
- relevant path arguments.

Do this before logging/signing/execution so the recorded contract and executed contract cannot diverge.

---

## 7. MEDIUM/HIGH - Environment values are written verbatim to logs and traces

**Status:** Reproduced in CI  
**Area:** task record + `_report()` + `_trace_line()`

Relevant source:

https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L199-L232

The result record contains the full explicit `env` hash. `_report()` prints the record to the log, and `_trace_line()` removes only `stdout` and `stderr`.

The audit used:

```perl
env => { API_TOKEN => 'audit-secret-DO-NOT-LOG' }
```

and confirmed that the value appeared in both:

- the human log;
- the JSON trace.

### Important nuance

This behavior is substantially inferable from the documentation: the record documents `env`, and the trace says it contains every record field except stdout/stderr. So I would describe this as a **dangerous default / security footgun**, not a secret undocumented exfiltration mechanism.

### Why it matters

Environment variables commonly carry:

- API tokens;
- cloud credentials;
- database passwords;
- signing secrets;
- scheduler credentials.

SimpleFlow is specifically a logging/tracing tool, so accidental credential persistence is realistic.

### Recommended fix

Consider one of:

1. record only environment **keys** by default;
2. redact all explicit values unless `trace.env_values => 1`;
3. add a separate `secret.env` option whose values are never rendered;
4. support explicit redaction rules.

At minimum, document prominently next to `env`, `log.fh`, and `trace.fh` that values are persisted verbatim.

Command strings can contain secrets too, so the same warning should cover credentials embedded directly in `cmd`.

---

## 8. MEDIUM/HIGH - `parallel()` can let a child unwind back into caller code when result serialization fails

**Status:** Reproduced in CI  
**Area:** `parallel()` child branch  
**Source:** around line 1762

https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1748-L1768

The intended child path is:

```perl
my $record = eval { task(...) };
my $error = $@;
Storable::nstore(...);
_flush(...);
POSIX::_exit(0);
```

The comment correctly explains why `_exit()` is important: ordinary Perl unwinding/exit can run inherited destructors and `END` blocks.

However, `Storable::nstore()` is **outside** the `eval`.

### Reproduction

`task()` currently accepts a CODE-valued `note` because `note` is not scalar-type checked.

- `parallel(jobs => 1, ...)` accepts the task.
- `parallel(jobs => 2, ...)` tries to Storable-serialize the result.
- Storable throws `Can't store CODE items`.
- the child never reaches `POSIX::_exit(0)`.

The audit's Test::Builder output visibly demonstrated the forked child continuing to unwind through the caller/test harness, which is exactly the scenario the `_exit()` comment intends to prevent.

### Impact

Depending on the embedding program, the forked child may:

- execute caller exception paths;
- run `END` blocks;
- run destructors inherited from the parent;
- write duplicated buffered/application output;
- perform application cleanup twice;
- produce confusing or corrupt test/log output.

### Recommended fix

Two layers:

1. Validate every field copied into the serializable result record. `note` should almost certainly be a plain scalar (or undef).
2. Wrap the **entire parallel child body**, including serialization and flush, in a final safety envelope that always terminates with `POSIX::_exit`.

If serialization fails, write a minimal serialization-safe error envelope back to the parent, then `_exit`.

---

## 9. MEDIUM - `timeout` destroys caller periodic `ITIMER_REAL` behavior and loses sub-second precision

**Status:** Periodic-timer damage reproduced in CI  
**Area:** `_run_forked()` / `_restore_alarm()`  
**Source:** lines 514 and 664-672

https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L507-L520

https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L664-L672

SimpleFlow preserves a caller alarm with:

```perl
my $caller_alarm = alarm(0);
```

and later restores:

```perl
alarm POSIX::ceil($left);
```

This preserves only a one-shot whole-second alarm.

### Reproduction

The audit installed:

- an initial real-time timer of 5 seconds;
- a repeat interval of 2 seconds.

After a timed SimpleFlow task:

- a one-shot alarm remained;
- the repeat interval was **0**.

### Additional consequence

A sub-second caller timer is rounded to whole seconds on restoration.

### Recommended fix

Where supported, use `Time::HiRes::getitimer` / `setitimer` and preserve:

- remaining time;
- repeat interval;
- fractional precision.

If SimpleFlow must defer the caller's alarm during its own timeout handling, document that behavior explicitly.

---

## 10. MEDIUM - Capture semantics can make successful binary output fatal depending on caller PerlIO layers

**Status:** Reproduced in CI  
**Area:** `_slurp_into()`  
**Source:** around lines 687-706

https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L687-L706

SimpleFlow records the caller's STDOUT/STDERR translation layers, redirects the underlying descriptors to temporary files, then reapplies selected layers (`crlf`, `utf8`, `encoding(...)`) while reading the captured bytes back.

A subprocess, however, writes bytes to file descriptors. It does not pass through the parent's PerlIO encoding layer.

### Reproduction

The audit gave the caller a `:encoding(UTF-8)` STDOUT and ran a successful child that wrote raw byte `0xFF`.

The command itself succeeded, but `task()` died while reading the capture because the inherited decoding expectation rejected the child's raw byte.

### Impact

Whether a command is considered successful can depend on an unrelated PerlIO layer on the embedding program's STDOUT/STDERR.

Binary tools are especially affected.

### Recommended fix

Capture subprocess output as raw bytes by default.

If decoded text is desirable, make it an explicit task-level policy such as:

```perl
'stdout.encoding' => 'UTF-8'
```

rather than deriving subprocess-decoding semantics from the caller's Perl handle.

---

## 11. MEDIUM - Full stdout/stderr capture is unbounded in memory

**Status:** Source-confirmed design risk  
**Area:** `_capture()` / `_slurp_into()`

The printed/logged record is clipped, but the actual result record deliberately retains complete stdout/stderr.

The implementation captures into temporary files and then slurps the full files into scalars.

This is much more memory-efficient than the older implementation, but it still means a command that emits tens of gigabytes can cause the SimpleFlow parent to allocate tens of gigabytes after the command completes.

### Impact

A runaway or adversarial command can exhaust:

1. temporary-disk space during capture; then
2. parent memory during slurp.

`timeout` does not impose an output-size bound.

The README advises using `stdout.file` / `stderr.file` for chatty commands, which is good operational advice, but a workflow manager should ideally have a safety ceiling.

### Recommended fix

Add configurable limits, for example:

```perl
'capture.max.bytes' => 64 * 1024 * 1024
```

with one of these policies:

- fail the task when exceeded;
- keep head/tail and mark truncation;
- spill permanently to a named file;
- return a file-backed object.

---

## 12. MEDIUM - `env => { NAME => undef }` does not have the documented removal meaning inside Docker/Podman images

**Status:** Source-confirmed; container runtime not exercised in audit CI  
**Area:** `_wrapped_cmd()` Docker/Podman construction

SimpleFlow documents `undef` as "remove the variable for the command."

Before execution, the host-side `%ENV` entry is indeed deleted.

But Docker/Podman construction only passes `-e NAME` for **defined** entries:

```perl
map { ('-e', $_) }
grep { defined $r->{env}{$_} }
sort keys %{ $r->{env} }
```

If the container image itself defines `NAME` using Dockerfile `ENV`, omitting `-e NAME` does not remove the image's default.

Docker's current CLI documentation says that `docker run -e NAME` with no `=` and with the variable absent from the host makes that variable unset in the container. That means SimpleFlow could preserve its documented semantics by passing the key even after removing it from its own host environment.

Docker reference:

https://docs.docker.com/reference/cli/docker/container/run/#set-environment-variables--e---env---env-file

### Recommended fix

For Docker/Podman, include `-e NAME` for keys explicitly set to `undef`, while ensuring the host-side variable is absent.

Add an integration test using an image whose Dockerfile sets a default environment variable.

---

## 13. MEDIUM - Internal lock/state files trust filesystem object types too much

**Status:** Source-level hardening finding  
**Areas:** `_lock_outputs()`, `.simpleflow`, signature files

Lock files are opened with:

```perl
open my $fh, '>>', $lock_file
```

without checking whether the path is:

- a regular file;
- a symlink;
- FIFO;
- device;
- unexpected hard link.

The signature hierarchy has the stronger concrete symlink vulnerability described in finding 1.

### Impact

In a shared-writable workspace, a malicious or accidental filesystem object can cause:

- writes through symlinks;
- blocking on a FIFO;
- locks to be taken on an unintended underlying file;
- denial of service.

### Recommended fix

Treat `.simpleflow` as a private internal namespace:

- verify directory ownership/type;
- avoid following symlinks;
- use `sysopen`;
- reject unexpected file types;
- consider private permissions.

---

## 14. MEDIUM - Parallel children sharing one log/trace handle can interleave/corrupt output

**Status:** Source-level concurrency risk; not stress-tested  
**Area:** `parallel()` + `_report()`

Forked parallel tasks inherit the same `log.fh` / `trace.fh`.

The human record is emitted by Data::Printer and related calls, which can involve multiple writes. Multiple children can therefore interleave records.

The trace does one Perl `print` per JSON line, but Perl does not provide a general guarantee that arbitrarily large writes from multiple processes to a regular file will remain an indivisible logical record.

### Impact

- human logs can become difficult to parse;
- JSONL trace lines can theoretically interleave/corrupt;
- the generated HTML report may then refuse the trace as invalid JSON.

### Recommended fix

Serialize cross-process log/trace writes, for example:

- `flock` around each complete record; or
- have parallel children return records only and let the parent write logs/traces; or
- use a dedicated logging process/pipe.

---

## 15. MEDIUM - Parallel error paths do not consistently guarantee child cleanup

**Status:** Source-level review finding  
**Area:** `parallel()`

The normal signal path terminates/waits for running children, but exceptional errors in the parent loop do not have a general `finally`/guard that kills and reaps every child.

Examples worth fault-injection testing:

- `fork()` failure after some tasks are already running;
- temporary-file creation failure;
- unexpected exception while processing returned records;
- caller exceptions/signals outside the explicitly handled HUP/INT/QUIT/TERM set.

### Impact

An exceptional parent failure can leave already-started work running after `parallel()` has unwound.

### Recommended fix

Use a scope guard around `%running` that, on abnormal exit:

1. sends termination to owned children;
2. waits/reaps them;
3. then propagates the original exception.

---

## 16. MEDIUM - Output declarations can overlap in ways that make failure moves inconsistent

**Status:** Source-level path-consistency finding  
**Area:** output validation + `_move_aside()`

SimpleFlow does not appear to reject overlapping output declarations.

Example:

```text
output.dir  = result/
output.file = result/item.txt
```

On failure, the child path may be moved first and then the parent directory moved. A `failed.outputs` entry recorded before the parent move can consequently refer to a path that no longer exists under that name.

More dangerous collisions exist when one declared output is another output's `.failed` name.

### Recommended fix

Normalize outputs and reject:

- duplicates after canonicalization;
- parent/child output overlaps;
- collisions with SimpleFlow's own sidecar/internal names.

Moving all failed outputs into one unique internal quarantine tree would remove many of these cases at once.

---

## 17. MEDIUM/LOW - `stale` silently tolerates unreadable directory subtrees

**Status:** Source-level finding  
**Area:** `_tree_mtime()`

`File::Find` warnings are suppressed:

```perl
no warnings 'File::Find';
```

An unreadable subtree can therefore be skipped when determining the newest mtime.

### Impact

With `stale => 1`, SimpleFlow can make a "current" decision using an incomplete input tree.

This is a workflow-integrity problem: inability to inspect part of an input should generally be "unknown/error," not silently "unchanged."

### Recommended fix

Collect `File::Find` traversal errors and either:

- fail the stale check; or
- conservatively consider the task stale.

---

## 18. MEDIUM - Windows list-form arguments containing `"` are known to be unreliable, but module validation does not enforce the limitation

**Status:** Source/test-suite portability finding; no live Windows runner used for this audit

The 0.191 tests contain explicit helpers that reject double quotes in list `cmd`/wrapper values because the Windows `system(LIST)` path does not quote them correctly.

That protects the test suite from false failures, but an application can still pass the same argument to SimpleFlow.

### Impact

On Windows, the advertised "array ref runs without a shell, so arguments need no quoting" guarantee is incomplete for arguments containing double quotes.

### Recommended fix

Either:

- implement correct Windows command-line quoting/spawn behavior; or
- reject unsupported argv strings on MSWin32 with a precise error; and
- document the restriction next to the array-form safety guarantee.

---

## 19. LOW/MEDIUM - Lock acquisition has no timeout, and task timeout starts only after locking

**Status:** Source-level availability finding

Output locks are acquired before `_run_once()` starts the command timer.

Therefore:

```perl
lock => 1,
timeout => 30,
```

can still wait indefinitely for another live process that holds the lock.

The documented timeout is specifically a command wall-clock timeout, so this is not necessarily a contract violation, but it is operationally surprising.

### Recommended fix

Consider:

```perl
'lock.timeout' => ...
```

or document explicitly that command timeout does not bound lock wait.

---

## 20. LOW/MEDIUM - Log and trace write failures are not consistently checked

**Status:** Source-level reliability finding

The module's purpose includes durable logging, but several `say` / `print` operations to caller-provided log and trace handles do not check their return values.

Disk-full, quota, filesystem, or broken-pipe errors can therefore leave diagnostic output incomplete without a direct task-level indication.

### Recommended fix

Centralize log/trace writes and check success. Decide policy explicitly:

- fatal;
- warning + record flag;
- callback/error collector.

For the JSONL trace in particular, partial writes should never be silently accepted.

---

## 21. LOW - `stale.cmd` uses MD5 for correctness state

**Status:** Hardening recommendation

`Digest::MD5` is used for both:

- lock filenames derived from output paths;
- command signatures used by `stale.cmd`.

For lock filenames, a collision mostly causes unnecessary lock sharing.

For `stale.cmd`, a digest collision creates a false "unchanged command" result.

This is not the highest priority issue because the confirmed representation bugs in finding 5 are far easier to trigger than a cryptographic MD5 collision. Still, for new correctness state there is little reason to choose MD5 today.

### Recommended fix

After moving to canonical structured signature input, use SHA-256.

---

## 22. LOW - Some execution-related option combinations are accepted but ignored

**Status:** Source-level API review

SimpleFlow validates some meaningless combinations (`executor.args` with local executor, `container.args` without container), which is good.

Other combinations can be accepted while doing nothing, such as resource-oriented values with local execution.

Typos/misunderstandings in workflow configuration are safer when rejected than silently ignored.

### Recommended fix

Review every option for "applicable only when X" constraints and make the validation policy consistent.

---

## 23. LOW - Custom JSON report parser is permissive and has no explicit resource bounds

**Status:** Source-level hardening finding  
**Area:** `_json_decode()` / `_json_value()`

The parser is used on trace files rather than arbitrary network input, so risk is limited.

Still, an untrusted or damaged trace can drive:

- deep recursive nesting;
- very large strings/objects;
- malformed Unicode edge cases.

### Recommended fix

If Perl 5.10 support requires keeping the custom parser, consider:

- maximum nesting depth;
- maximum line size;
- stricter control-character handling.

Otherwise, prefer a maintained JSON implementation when available.

---

## 24. LOW - `$^P` compile-time restoration depends on reaching the final `BEGIN`

**Status:** Source-level side-effect edge case

The module sets debugger flags early during compilation and restores them in a `BEGIN` near the end of the code.

If module compilation aborts before that final restoration point (for example, due to an unavailable dependency or syntax/load-time failure), the process can be left with modified `$^P` flags.

This is unlikely in a correctly installed distribution, but it is a global-state cleanup edge case.

---

# Additional observations

## Shell injection boundary is documented correctly

`SECURITY.md` explicitly says string-form `cmd` is passed to a shell and that untrusted data should be passed via array-form `cmd`.

That is the right distinction. I do **not** count caller-built shell strings as a SimpleFlow vulnerability.

The Windows argument caveat in finding 18 is separate: it concerns whether the array form faithfully preserves argv on that platform.

## Failure preservation is a good goal; the namespace choice is the problem

Moving partial outputs away after a failed task is an important correctness improvement. The problem is not the feature itself; it is deriving a destructive backup name from user output with a fixed `.failed` suffix and treating anything already there as disposable.

A unique internal quarantine tree would preserve the good behavior while eliminating several edge cases at once.

## The source shows unusually strong attention to regressions

The `Changes` file and tests document many prior failures in detail, including signal races, partial output reuse, file-descriptor handling, old-Perl behavior, and Windows CPAN smoker differences.

The findings in this report are mostly cross-feature interactions and hostile-boundary cases, not evidence that the existing suite is weak. In fact, the upstream 152-test suite passed cleanly before these additional probes.

---

# Recommended repair order

If David wants to triage rather than address everything at once, I would use this order:

1. **Secure `_write_signature()`** against symlink/temp-file attacks.
2. **Redesign failed-output quarantine** to eliminate destructive fixed `.failed` replacement and trailing-slash/path-overlap bugs.
3. **Make child ownership robust around `SIGCHLD`**, especially preventing the `parallel()` infinite loop.
4. **Redesign `stale.cmd` canonical signatures** and reject NUL at all execution boundaries.
5. **Harden `parallel()` child termination/serialization** so every child reaches `_exit()`.
6. **Decide secret-recording policy for `env`** and add redaction/documentation.
7. **Fix timer preservation and raw capture semantics.**
8. Add output-size bounds and cross-process log/trace serialization.
9. Address container/Windows portability semantics.
10. Work through the lower-risk hardening items.

---

# Suggested regression tests to add upstream

A compact permanent suite should cover at least:

1. `local $SIG{CHLD} = 'IGNORE'` around a successful `task()`.
2. Same around `parallel(jobs => 2)` with a safety bound.
3. A caller `SIGCHLD` handler that itself reaps children.
4. `stale.cmd` change `threads => 1` to `threads => 2`.
5. `stale.cmd` change `stdin => devnull` to `stdin => inherit`.
6. Distinct wrapper argv vectors that stringify identically.
7. Reject NUL in argv and environment values.
8. `output.dir => "name/"` failure behavior.
9. Pre-existing unrelated `name.failed` must survive.
10. Nested/overlapping output declarations are rejected.
11. Pre-planted symlink at signature temporary path does not modify its target.
12. Caller repeating `ITIMER_REAL` survives a timed task.
13. Binary `0xFF` child stdout survives independently of caller `:encoding(UTF-8)`.
14. Result-record values accepted by `task()` are always serializable by `parallel()`.
15. Log/trace records from many parallel tasks remain parseable and non-interleaved.
16. Container `env => { NAME => undef }` removes an image-defined `NAME`.
17. Windows list-form argv containing quotes either round-trips correctly or is rejected clearly.
18. Capture limit behavior under a deliberately large writer.

---

# Audit evidence

## Source snapshot

Main snapshot audited:

https://github.com/haxmeister/SimpleFlow/commit/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba

## Audit branch

The reproducibility probes are intentionally kept separate from main:

https://github.com/haxmeister/SimpleFlow/tree/audit/simpleflow-review-20261002

The branch contains:

- `audit/simpleflow-review.t`
- `.github/workflows/simpleflow-audit.yml`

They are audit instrumentation, not proposed production changes.

## CI verification

Completed run:

https://github.com/haxmeister/SimpleFlow/actions/runs/37077375245

Environment:

- Ubuntu 24.04
- Perl 5.40.5
- Data::Printer 1.002001
- Devel::Confess 0.009004
- Devel::Size 0.87

Baseline:

```text
Files=9, Tests=152
All tests successful.
Result: PASS
```

Audit:

```text
1..14
All tests successful.
Result: PASS
```

The audit assertions intentionally describe the current problematic behavior. The Storable/CODE test visibly demonstrates the forked-child unwind problem by producing duplicate Test::Builder output from the child before the parent completes the top-level subtest.

---

# Areas not fully integration-tested

The review was intentionally broad, but the following deserve dedicated environments before making claims stronger than the source-level findings above:

- native Windows execution/quoting behavior;
- real Docker and Podman runs;
- Singularity/Apptainer environment behavior;
- a real SLURM cluster;
- NFS/cluster-filesystem `flock` behavior;
- pseudo-terminal foreground/background job control;
- hostile multi-user shared-directory tests using distinct Unix UIDs;
- disk-full/quota fault injection;
- fork/pipe/file-descriptor exhaustion fault injection;
- very old supported Perl versions for every new adversarial probe.

Those limitations do not affect the CI-reproduced findings on Linux, but they should shape portability conclusions.

---

# Final assessment

SimpleFlow 0.191 has a strong ordinary regression suite and substantial defensive work around command execution, signals, retries, output validation, and diagnostics. The audit nevertheless found several interactions that can violate core workflow guarantees: stale results can be accepted as current, failed outputs can remain under their declared names, unrelated data can be deleted by backup-name collision, and external process-management policy can make child accounting fail or hang.

The most security-sensitive item is the predictable symlink-following signature write in a shared-writable workspace. The most important correctness themes are failed-output path handling, `SIGCHLD` ownership, and canonical `stale.cmd` identity.

I would recommend fixing those areas before adding more workflow features, because they sit underneath the reproducibility and safety guarantees that the higher-level features depend on.
