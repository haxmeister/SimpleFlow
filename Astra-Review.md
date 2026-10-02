# SimpleFlow 0.191: independent Astra review

Prepared for Joshua S. Day and David E. Condon on October 2, 2026.

**The highest-priority confirmed problems are destructive failure cleanup,
incorrect reuse of cached results, and corrupted traces from parallel tasks.**
The existing test suite passes, but the additional checks below expose behavior
that it does not cover.

This report contains **10 confirmed findings** (F01-F10), followed by process
management concerns and security hardening items found by source inspection.
Those later items are explicitly not represented as reproduced vulnerabilities.
Severity describes potential workflow impact, not a CVSS score.

## Baseline, independence, and scope

| Item | Reviewed value |
| --- | --- |
| Repository | `haxmeister/SimpleFlow` |
| Starting branch | `main` |
| Starting commit | `b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba` |
| Module version | `0.191` |
| Report branch | `Astra-Review` |
| Primary implementation | `lib/SimpleFlow.pm`, including its POD |
| Published release | `DCON/SimpleFlow-0.191.tar.gz` |
| Runtime used for checks | Linux x86-64, threaded Perl 5.38.2 |

Only `main` was downloaded for the source baseline. No other review branch,
review report, or issue discussion was consulted. The new branch starts at the
commit above. No production implementation, existing tests, or release metadata
was changed.

The review covered command execution, capture and restoration of standard
streams, signals and timeouts, retries, output validation and cleanup, file and
directory staleness, command signatures, locks, permissions, task defaults,
hooks, parallel workers, trace encoding, HTML reports, documentation, and
published distribution metadata. Container/conda/SLURM command construction was
read, but those backends were not executed.

The CPAN archive was downloaded independently from
[the CPAN mirror](https://cpan.metacpan.org/authors/id/D/DC/DCON/SimpleFlow-0.191.tar.gz).
Its module is byte-for-byte identical to the reviewed Git module. Every archive
file that has a corresponding path in the source checkout also matches.

```text
lib/SimpleFlow.pm SHA-256:
8c6c9daeffa29ab84f526dc9ac388d3c2bda4395a4d7572f0137647ff47d1040

SimpleFlow-0.191.tar.gz SHA-256:
43e5a233d876c93efcf65173fe90e137de883d33946e1a63d74f488d088f020e
```

All source links below are pinned to the reviewed commit, so later edits will
not silently change the cited evidence.

## Verification results

| Check | Result |
| --- | --- |
| Original suite, `prove -lr t` | PASS: 9 files, 152 top-level tests/subtests, 24 seconds |
| New desired-behavior checks, `prove -v review/astra/correctness.t` | FAIL as expected on this baseline: 11 of 11 top-level subtests |
| POD syntax, `podchecker lib/SimpleFlow.pm` | PASS |
| Text POD rendering | Argument and return-field tables disappear; F10 |
| CPAN manifest versus archive | No missing listed files or unlisted regular files |
| CPAN META.json | Parses successfully; version and module mapping agree |

The new checks use small, disposable local fixtures. They are outside `t/` and
are not part of the normal distribution suite. They assert the intended
behavior, rather than treating a demonstrated bug as a passing expectation.
F01 has three checks, so eleven runtime subtests cover F01-F09. F10 was verified
by rendering the POD. The concurrent trace check is timing-dependent on the
affected implementation; a single passing run would not disprove the defect.

Run the added checks from the repository root after installing the distribution's
declared test dependencies:

```sh
prove -v review/astra/correctness.t
```

These added fixtures require POSIX fork behavior and skip on MSWin32. No Windows,
BSD, alternate-Perl-version, interactive-terminal, or real scheduler/container
execution is claimed by this report. The bundled tests' conditional skips were
not turned into evidence of support for those environments. See
`review/astra/VALIDATION.txt` for the dependency versions and recorded results.

## Confirmed findings at a glance

| ID | Priority | Finding |
| --- | --- | --- |
| F01 | High | Failure cleanup can delete results when output names duplicate or overlap |
| F02 | High | Parallel workers can interleave and corrupt JSON trace records |
| F03 | High | A run without `stale.cmd` leaves older command metadata authoritative |
| F04 | High | Different wrapper argument lists can have the same command signature |
| F05 | Medium | Changing local `threads` does not invalidate the cached result |
| F06 | Medium | Output locking crashes on a valid Unicode character-string filename |
| F07 | Medium | A redirected stream that is also an output loses its promised attempt history |
| F08 | Medium | Moving a declared stderr output hides the actual diagnostic from the failure message |
| F09 | Medium | A scalar-backed STDIN is broken by a normal task call |
| F10 | Low | Essential API tables are absent from ordinary text/manpage documentation |

### F01. Failure cleanup can destroy the data it is meant to preserve

**Confirmed with three ordinary output-list configurations.**

**Source:** [`_move_aside`, lines 395-415](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L395-L415);
[`_normalise_files`, lines 346-382](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L346-L382);
[cleanup and record assignment, lines 1593-1601](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1593-L1601).

The cleanup loop first collects all existing output names, then processes them
one by one. Each iteration removes an existing `<name>.failed` before renaming
the original. Output lists are not deduplicated and destinations are not checked
against other declared outputs.

Observed cases:

| Declaration | Observed result after a failing task |
| --- | --- |
| `output.files => ['out', 'out']` | The first iteration creates `out.failed`; the second removes it and cannot rename the now-absent `out`. Both paths are gone, while `failed.outputs` still lists `out.failed`. |
| `output.files => ['out', 'out.failed']` | The original contents of the second declared output are deleted. The final `out.failed.failed` contains the first output's contents instead. |
| `output.file => 'out/item'` and `output.dir => 'out'` | The file is moved inside the directory, then the directory is moved. `failed.outputs` reports `out/item.failed`, but the actual retained file is `out.failed/item.failed`. |

The first two are real data loss, not just an inaccurate diagnostic. Lists
assembled from multiple pipeline components can acquire duplicates without any
malicious input. An unrelated pre-existing `.failed` file or directory is also
removed without establishing that SimpleFlow created it.

**Suggested fix:** validate and normalize the complete output set before
execution. Deduplicate identical outputs, establish a policy for aliases and
parent/child outputs, and calculate a collision-free move plan before deleting
or renaming anything. Preserve unknown existing destinations rather than
recursively removing them. Record the final paths that actually exist.

### F02. Concurrent trace writes can produce invalid JSON

**Confirmed with 16 successful tasks, 8 workers, and large plain-text notes.**

**Source:** [`_report`, lines 199-209](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L199-L209);
[parallel worker execution, lines 1731-1766](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1731-L1766).

Every worker writes its own trace directly through the inherited filehandle.
Autoflush does not turn an arbitrarily long Perl `print` into an indivisible
record write. There is no interprocess record serialization.

The fixture returned all 16 task records and wrote 16 physical lines, but some
lines contained interleaved parts of different JSON records. Separate observed
runs produced 2 and 4 invalid lines. The notes were ordinary ASCII text of about
96-108 KB per task; neither malformed JSON nor special characters were supplied.

**Impact:** a successful workflow can leave an unreadable trace; `report()` then
rejects it. The documented claim that shared log output interleaves a record at
a time also needs review, although only JSON trace corruption was established
by this test.

**Suggested fix:** have the parent emit complete trace records after collecting
worker results, or introduce genuine interprocess serialization. Merely adding
`flock` to the same inherited open file description is not a sufficient design:
workers need independently acquired locking ownership. Handle write failures as
well as record boundaries.

### F03. Command metadata survives an intervening run that replaced the output

**Confirmed with a three-call workflow.**

**Source:** [signature lookup, lines 1492-1503](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1492-L1503);
[successful-run update, line 1641](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1641).

The first call runs command A with `stale.cmd => 1` and records signature A.
A second call runs command B over the same output with `overwrite => 1` and
without `stale.cmd`. The third call requests A with `stale.cmd => 1` again.

Observed: the third call returns `done => 'before'`, `cmd.changed => 0`, and
leaves B's output in place. The signature describes the first run, not the run
that produced the current file. The same effect was observed when the original
output was removed and then recreated by B without `stale.cmd`.

**Impact:** cached results can silently belong to a different command. Changing
defaults, temporarily disabling this option, or sharing outputs between callers
is enough to enter this state.

**Suggested fix:** maintain or invalidate existing provenance whenever
SimpleFlow executes a task that replaces the associated outputs, even when that
call does not request signature-based skipping. Missing or invalidated
provenance must not silently reactivate the old signature. The documented
adoption policy for outputs with no known provenance needs to be reconciled with
this transition; simply deleting metadata and immediately adopting any existing
output as the requested command is not enough to guarantee a rerun.

### F04. Wrapper argument boundaries are lost in command signatures

**Confirmed with two different argument lists and an unchanged base command.**

**Source:** [display command construction, lines 1410-1415](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1410-L1415);
[`_command_signature`, lines 1015-1022](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1015-L1022).

The original `cmd` array keeps its word boundaries in the digest. The wrapped
command does not: its array is flattened with spaces for display, and that
display string is what gets hashed.

In the fixture, a wrapper receiving one argument `a b` and one receiving two
arguments `a`, `b` produce the same display string. They have different behavior:
the wrapper writes the arguments separated by `|`. The second task is skipped
with `cmd.changed => 0`; the output remains `a b|tail` instead of `a|b|tail`.

This is an ambiguity in serialization, not a cryptographic collision in MD5.
The same construction warrants checks for container and executor argument
arrays, without claiming those backends were exercised here.

**Suggested fix:** hash a canonical representation of the actual execution argv
and relevant options. Preserve argument boundaries and types. Keep the
space-joined value only as a human-readable display field.

### F05. Local thread settings do not participate in cache invalidation

**Confirmed.**

**Source:** [effective command environment, lines 831-851](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L831-L851);
[`_command_signature`, lines 1015-1022](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1015-L1022).

For a plain local command, `threads` sets `SIMPLEFLOW_THREADS` in the child's
environment. It is absent from the signature, which hashes only the explicit
`env` hash and the displayed wrapped command.

A command that writes `SIMPLEFLOW_THREADS` to its output was run with
`threads => 1`, then requested with `threads => 2`, both with `stale.cmd => 1`.
The second call was skipped and the output remained `1`.

**Impact:** a changed execution setting is ignored. Some programs change their
algorithm, partitioning, or result ordering based on this value.

**Suggested fix:** derive the signature from the effective execution
configuration, including SimpleFlow-generated environment variables. Include a
regression for transitions between omitted, explicit, and changed `threads`.

### F06. Locking fails on Unicode character-string output paths

**Confirmed with a pre-existing filename containing U+03BB.**

**Source:** [`_lock_outputs`, lines 447-470](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L447-L470),
especially line 459.

With `lock => 1`, the path is passed directly to `md5_hex`. Digest::MD5 requires
bytes, so a Perl character string containing a code point above 255 dies with
`Wide character in subroutine entry`. This happens before an otherwise valid
existing output can be skipped.

The neighboring `_signature_file` and `_command_signature` routines explicitly
encode character strings before hashing them; `_lock_outputs` does not.

**Suggested fix:** define one path-to-bytes representation and use it consistently
for metadata and locks, accounting for character strings versus filesystem byte
strings that name the same file. Add non-ASCII path cases to locking tests.

### F07. Stream/output overlap changes retry logging behavior

**Confirmed documentation/behavior conflict.**

**Source:** [initial stream truncation, lines 1561-1565](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1561-L1565);
[failure cleanup, lines 1593-1596](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1593-L1596);
[documented all-attempt behavior, lines 2695-2711](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L2695-L2711).

The documentation says redirected stdout/stderr files receive every attempt in
order. If `stdout.file` is also the declared `output.file`, the first failed
attempt moves that file aside. The retry appends to a newly created original
path instead.

Observed: a task that printed `first` and failed, then printed `second` and
succeeded, returned `attempts => 2`. The requested output contained only
`second\n`; `first\n` was in `.failed`. With more failed attempts, the same
backup destination is replaced again. Files inside a declared output directory
need the same interaction reviewed.

**Suggested resolution:** explicitly distinguish result data from cumulative
attempt logs. Combining failed stdout with a successful data product may itself
be undesirable, so a fix should not blindly concatenate everything. Either
preserve a separate all-attempt log and document result-file semantics, or reject
ambiguous configurations. The supplied test encodes the current documented
all-attempt promise; an intentional contract change should update it.

### F08. A moved stderr file no longer supplies the failure-message tail

**Confirmed using a separate fixture script, so the diagnostic is not embedded
in the displayed command.**

**Source:** [`_stderr_tail`, lines 1070-1090](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1070-L1090);
[cleanup at line 1594](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1594);
[tail construction at lines 1660-1665](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1660-L1665).

When the same path is named by `stderr.file` and `output.file`, cleanup renames
it before `_stderr_tail` tries to read it. That helper still opens the original
name and quietly returns no lines if it is absent.

Observed: the fixture exited 7 and wrote `fixture diagnostic`. The message was
present in `err.failed` but absent from the exception returned by `task()`.

**Suggested fix:** collect the diagnostic tail before moving outputs, or retain
and use an original-to-final-path mapping. Apply the same treatment when an
output directory contains the stderr file.

### F09. Scalar-backed STDIN cannot be restored

**Confirmed in a fresh interpreter with a small in-memory input string.**

**Source:** [STDIN setup, lines 825-833](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L825-L833);
[restoration, lines 888-897](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L888-L897).

The code tests only whether `fileno STDIN` is defined before treating STDIN as a
duplicable OS file descriptor. A scalar-backed PerlIO handle is an open handle
but does not provide that kind of descriptor.

A task whose command simply exits successfully instead dies while restoring
STDIN: `cannot restore STDIN ... Bad file descriptor`. The caller then cannot
read the original input string.

**Suggested fix:** keep PerlIO-handle state separate from descriptor 0. Redirect
the child's input or save/restore descriptor 0 without reopening the caller's
Perl-level handle. Define support for scalar or localized standard handles. If
unsupported, reject them before changing any caller state. Also examine the
assumption that the STDIN glob always corresponds to descriptor 0.

An ordinary file-backed STDIN with already buffered lines retained its next line
in a separate check; this report does not claim general buffered-input loss.

### F10. Text POD omits the argument and return-field tables

**Confirmed by `pod2text`; POD syntax checking still passes.**

**Source:** [argument table, lines 2167-2437](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L2167-L2437);
[return documentation, lines 2439-2561](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L2439-L2561).

The tables are HTML-only `=begin html` sections. Text and manpage formatters
discard them. The rendered `Arguments` section starts immediately with prose
after the table; the return section promises fields "below" that never appear.

**Impact:** a user reading installed documentation with ordinary `perldoc`
cannot see the complete option types/defaults or return-field definitions.

**Suggested fix:** generate portable POD lists with `=over`/`=item`, or provide a
text fallback alongside the HTML table. Check rendered text as well as syntax.

## Process-management concerns established by source inspection

These are actionable review targets, with explicit reasons for concern. They
were not exercised through fault injection, hostile commands, or exploit
reproduction. They are therefore separate from F01-F10.

### P01. Timeout setup depends on descriptor inheritance assumptions

**Source:** [lines 516-577](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L516-L577)
and [lines 590-608](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L590-L608).

The exec-status pipe relies on Perl's default close-on-exec behavior and the
caller's `$^F`; the descriptor's flag is not explicitly set. The parent performs
a blocking read before installing its timed-wait handlers and arming the alarm.
If the write endpoint remains inherited, the stated command timeout does not
bound that setup wait. Signals are also still blocked during this read.

**Review/fix:** set close-on-exec explicitly and check errors. Use a deadline
that includes startup and every blocking stage. Handle exec-pipe read errors
and interruption distinctly from successful exec. Assess availability impact
when SimpleFlow is embedded in programs with nondefault descriptor handling.

### P02. An already-reaped worker is never removed from the running set

**Source:** [lines 1770-1791](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1770-L1791).

`parallel()` recognizes only `waitpid(pid, WNOHANG) == pid` as a completed worker.
It does not handle a `-1` result. In an application that automatically reaps
children or has another SIGCHLD handler collecting them, the stored PID can
remain in `%running` forever even though the worker no longer exists.

**Review/fix:** define child-status ownership, distinguish retryable interruption
from `ECHILD`, and turn an irrecoverably unavailable status into a bounded error
instead of polling indefinitely. Avoid interfering with unrelated caller
children while doing so.

### P03. Parallel exception paths lack a complete worker-lifecycle guard

**Source:** [lines 1754-1768](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1754-L1768)
and [lines 1781-1796](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1781-L1796).

In the worker, only `task()` is inside `eval`; serialization and flushing are
outside it. A serialization/I/O exception can escape the worker branch before
`POSIX::_exit`, potentially reaching a surrounding caller exception handler in
the forked copy of the application. In the parent, a later temporary-file or
fork failure exits the loop without a guard that waits for already-started
workers.

**Review/fix:** put the entire worker body behind an unconditional child-exit
boundary, with a minimal error-reporting fallback. Give the parent a cleanup
guard that accounts for every child on every exit. Also close the signal race
between `fork()` and adding the new PID to `%running`.

### P04. Signal forwarding without a timeout owns only the direct child

**Source:** [signal forwarding, lines 590-604](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L590-L604);
[unexpected-exception branch, lines 617-628](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L617-L628).

The untimed path forwards TERM/HUP to the direct child PID. It does not establish
ownership of all descendants of a shell pipeline. Whether descendants stop is
therefore dependent on the shell and programs involved. Separately, an
unexpected exception from a caller signal handler restores some state and dies
without an explicit child termination/reap path.

**Review/fix:** define and test cancellation semantics for command trees and
caller handlers that throw exceptions. Avoid claiming full descendant cleanup
from the direct-child case alone. Interactive terminal behavior will need its
own tests if process-group ownership changes.

## Security and trust-boundary review

No end-to-end third-party exploit was attempted or established. The following
items identify places where the implementation depends on trust or needs
hardening. Their severity depends on how an application uses SimpleFlow.

### S01. Working-directory metadata needs an explicit ownership policy

**Source:** [lock-file creation, lines 447-470](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L447-L470);
[signature-file writing, lines 1042-1054](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1042-L1054);
[permission changes, lines 421-436](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L421-L436).

Metadata paths are opened through ordinary path-based operations; the code does
not establish ownership or privacy of a pre-existing `.simpleflow` directory.
The signature staging name is predictable and opened with truncation rather
than exclusive creation. Symlink checks around output permission changes are
separate from the operation that uses the path.

If another principal can replace directory entries, the intended pathname is
not enough to establish the identity of the file being opened or changed.
This is a conditional shared-directory concern, not evidence that a normal
private workspace is exploitable.

**Recommendation:** use private, validated metadata directories; securely create
temporary files in the destination directory; use descriptor-based identity
checks and appropriate no-follow/exclusive-create behavior. Document the trust
requirements for output trees and workspaces.

### S02. Different names for the same output do not necessarily share a lock

**Source:** [lines 447-459](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L447-L459).

Lock identity is based on `File::Spec->rel2abs` and textual equality. That is not
filesystem identity resolution. Parent-directory aliases, symbolic links, or
hard links can name the same underlying output with different lock keys, even
within one working directory. Directory-output locks also do not establish a
hierarchical relationship with separately declared child-file locks.

**Recommendation:** define supported alias and parent/child-output semantics and
validate ambiguous output sets. This is primarily a concurrency/integrity issue;
the different-working-directory limitation is already documented and is not
being reported as a new defect.

### S03. Explicit environment values are copied into records and traces

**Source:** [record construction, lines 1370-1389](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1370-L1389);
[`_report` and `_trace_line`, lines 199-232](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L199-L232).

The trace removes stdout/stderr but keeps the entire explicit `env` hash.
Commands and explicit environment variables can carry credentials. They also
reach normal diagnostic records; `quiet` suppresses terminal chatter, not trace
or log output. This matches the broad "every field" documentation, but it is a
material operational risk when logs or reports are shared.

**Recommendation:** offer explicit redaction or an allowlist, separate the
execution environment from its printable representation, and warn in the API
documentation that sensitive values are recorded. No real credentials were
used or inspected in this review.

### S04. The custom JSON reader accepts more than valid JSON

**Source:** [lines 1959-2026](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1959-L2026);
[trace consumption, lines 1837-1855](https://github.com/haxmeister/SimpleFlow/blob/b8b7dcbd3a2a45296c0cc65370ddbe288484e2ba/lib/SimpleFlow.pm#L1837-L1855).

UTF-8 decoding success is not checked. The string parser accepts unescaped
control characters and does not reject isolated surrogate code points.
The report code checks for a top-level hash but does not validate the types or
ranges of fields used in arithmetic and date conversion. There are also no
explicit input-size or nesting limits.

**Recommendation:** prefer a maintained JSON decoder with clear limits and
validate the report schema before rendering. If traces can come from outside
the workflow, make those trust and resource limits explicit. These observations
are not a demonstrated code-execution vulnerability. The HTML renderer does
escape text fields through `_html`; no HTML/script injection was established.

## Additional edge cases and release observations

- **UTF-8 byte-string report titles:** a title supplied as UTF-8 bytes for
  `Report cafe` with an accented final e was encoded again. Observed bytes ended
  in `c3 83 c2 a9` instead of `c3 a9`. Character-string titles are a different
  case. Decide whether titles must be decoded Perl strings and document or
  normalize that contract. This low-priority encoding ambiguity is not counted
  among the ten primary findings.
- **Git checkout installation instructions:** the documented checkout command
  `perl Makefile.PL` cannot run at the reviewed repository root, which contains
  `dist.ini` but no `Makefile.PL`. The published CPAN archive does contain it.
  Explain the Dist::Zilla build step or distinguish release-archive installation
  from development checkout installation.
- **Old generated release artifacts in Git:** the root contains a 0.19 archive
  and unpacked 0.19 tree while the active module is 0.191. They were not used as
  the review baseline. They are absent from the inspected 0.191 CPAN archive;
  this is repository clarity, not a demonstrated packaging defect.
- **Backend integration:** check environment removal against container-image
  defaults, argument boundaries on Windows, path mounting rules, and scheduler
  cancellation using the actual supported backends. Dry-run string comparisons
  cannot establish those behaviors.
- **Inherited process state:** review high-resolution caller alarms, nondefault
  standard descriptors, custom SIGCHLD/signal handlers, and abrupt I/O failures.
  The process-management items above identify specific places to start.

## Behaviors not misclassified as new vulnerabilities

- Running a caller-supplied shell command string is the advertised API. Building
  that string from untrusted data is an application responsibility already
  explained in `SECURITY.md`.
- Array-form commands use explicit-program `exec`/`system` syntax. This review
  did not find a reason to report ordinary array execution as shell evaluation.
- Existing output adoption on the first use of `stale.cmd` is documented. F03
  concerns metadata known to be stale after a later SimpleFlow execution.
- Root bypassing ordinary write permission checks is documented for `protect`.
- The inspected release has a coherent manifest and metadata. Stale coverage
  HTML in the source repository was not treated as current test evidence.

## Suggested repair order

1. Prevent output loss in F01, including collisions and nested output sets.
2. Correct provenance/signature handling in F03-F05 so successful-looking runs
   cannot silently reuse the wrong result.
3. Serialize traces in F02 and close the worker-lifecycle issues P01-P04.
4. Resolve the stream, Unicode-path, and STDIN cases F06-F09.
5. Restore portable API documentation in F10 and document the trust boundaries.

After changes, run the original suite and the new focused regressions, then
exercise the modified areas across supported Perl versions and platforms.
This review is a set of independently evidenced findings and explicit follow-up
targets, not a claim that every possible bug or vulnerability has been excluded.
