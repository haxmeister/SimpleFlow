#!/usr/bin/env perl
# Independent Astra review: desired-behavior regressions for SimpleFlow 0.191.
# Run from the checkout: prove -v review/astra/correctness.t
# These tests intentionally fail on the audited baseline. They are separate
# from the distribution's normal suite. All files are temporary fixtures.
# POSIX only; security concerns in the report have no exploit test here.
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use File::Spec;
use FindBin;
use POSIX ();
plan skip_all => 'These review fixtures use a real fork' if $^O eq 'MSWin32';
my $lib=abs_path(File::Spec->catdir($FindBin::Bin,'..','..','lib'));
my $prelude=<<'ASTRA_PRELUDE';

use strict;
use warnings;
use SimpleFlow qw(task parallel report);
use JSON::PP;
use Cwd qw(getcwd);
use File::Spec;
sub spew { my ($p,$s)=@_; open my $f,'>',$p or die $!; print {$f} $s; close $f or die $! }
sub slurp { my $p=shift; open my $f,'<',$p or return undef; local $/; return <$f> }
sub emit { print JSON::PP->new->canonical->ascii->encode($_[0]), "\n" }
ASTRA_PRELUDE

sub fixture {
    my ($code)=@_;
    my $dir=tempdir(CLEANUP=>1);
    my $script=File::Spec->catfile($dir,'fixture.pl');
    open my $f,'>',$script or die $!;
    print {$f} $prelude,$code;
    close $f or die $!;
    my $pid=fork();
    die "fixture fork failed: $!" if not defined $pid;
    if (!$pid) {
        chdir $dir or POSIX::_exit(120);
        open STDOUT,'>','fixture.stdout' or POSIX::_exit(121);
        open STDERR,'>','fixture.stderr' or POSIX::_exit(122);
        no warnings 'exec';
        exec {$^X} $^X,'-I',$lib,$script;
        POSIX::_exit(123);
    }
    waitpid $pid,0;
    my $status=$?;
    open my $o,'<',File::Spec->catfile($dir,'fixture.stdout') or die $!;
    local $/;
    my $text=<$o>;
    close $o;
    my $got=eval { JSON::PP::decode_json($text) };
    if ($status || !$got) {
        open my $e,'<',File::Spec->catfile($dir,'fixture.stderr') or die $!;
        diag(<$e>);
        close $e;
        fail('fixture completed and returned observations');
        return {};
    }
    return $got;
}

subtest 'F01: duplicate outputs retain their partial result' => sub {
    my $r=fixture(<<'ASTRA_FIXTURE_0');

my $code=q{open my $f,'>','out' or die $!; print {$f} 'partial fixture'; close $f; exit 1};
my $r=task(cmd=>[$^X,'-e',$code],'output.files'=>['out','out'],quiet=>1,die=>0);
emit({out_exists=>-e 'out' ? 1:0,failed_exists=>-e 'out.failed' ? 1:0,reported=>$r->{'failed.outputs'}});
ASTRA_FIXTURE_0
    is($r->{failed_exists},1,'the documented .failed result still exists');
};

subtest 'F01: overlapping names retain both results' => sub {
    my $r=fixture(<<'ASTRA_FIXTURE_1');

spew('out','first fixture'); spew('out.failed','second fixture');
my $r=task(cmd=>[$^X,'-e','exit 1'],'output.files'=>['out','out.failed'],overwrite=>1,quiet=>1,die=>0);
emit({preserved=>[sort map {slurp($_)} grep {-f $_} glob('out*')],reported=>$r->{'failed.outputs'}});
ASTRA_FIXTURE_1
    is_deeply($r->{preserved},['first fixture','second fixture'],'both declared contents survive cleanup');
};

subtest 'F01: nested output records name real paths' => sub {
    my $r=fixture(<<'ASTRA_FIXTURE_2');

mkdir 'out'; spew('out/item','fixture');
my $r=task(cmd=>[$^X,'-e','exit 1'],'output.file'=>'out/item','output.dir'=>'out',overwrite=>1,quiet=>1,die=>0);
emit({reported=>$r->{'failed.outputs'},exists=>[map {-e $_ ? 1:0} @{$r->{'failed.outputs'}}],actual=>slurp('out.failed/item.failed')});
ASTRA_FIXTURE_2
    ok(!(grep { !$_ } @{$r->{exists} || []}),'every reported moved output exists');
};

subtest 'F02: parallel trace records remain complete JSON lines' => sub {
    my $r=fixture(<<'ASTRA_FIXTURE_3');

open my $trace,'>','trace.jsonl' or die $!;
my @r=parallel(jobs=>8,tasks=>[map { {cmd=>[$^X,'-e','select undef,undef,undef,0.2'],quiet=>1,note=>scalar(('worker'.$_.'-') x 12000),'trace.fh'=>$trace} } 1..16]);
close $trace;
open my $in,'<','trace.jsonl' or die $!;
my ($lines,$bad)=(0,0);
while (my $line=<$in>) { $lines++; my $r=eval { JSON::PP::decode_json($line) }; $bad++ if not defined $r; }
emit({records=>scalar @r,lines=>$lines,invalid_lines=>$bad});
ASTRA_FIXTURE_3
    is($r->{records},16,'all tasks returned'); is($r->{lines},16,'one line per task'); is($r->{invalid_lines},0,'no records interleaved; race-sensitive on the old code');
};

subtest 'F03: an intervening run invalidates old command metadata' => sub {
    my $r=fixture(<<'ASTRA_FIXTURE_4');

my $code=q{open my $f,'>','out' or die $!; print {$f} $ARGV[0]};
my @common=('output.file'=>'out',quiet=>1);
task(@common,cmd=>[$^X,'-e',$code,'A'],'stale.cmd'=>1);
task(@common,cmd=>[$^X,'-e',$code,'B'],overwrite=>1);
my $c=task(@common,cmd=>[$^X,'-e',$code,'A'],'stale.cmd'=>1);
emit({last=>$c->{done},changed=>$c->{'cmd.changed'},output=>slurp('out')});
ASTRA_FIXTURE_4
    is($r->{last},'now','old command is run again'); is($r->{output},'A','result matches the requested command');
};

subtest 'F04: wrapper argument boundaries affect the signature' => sub {
    my $r=fixture(<<'ASTRA_FIXTURE_5');

my $code=q{open my $f,'>','out' or die $!; print {$f} join('|',@ARGV)};
my @common=(cmd=>['tail'],'output.file'=>'out','stale.cmd'=>1,quiet=>1);
my $a=task(@common,wrapper=>[$^X,'-e',$code,'a b']);
my $b=task(@common,wrapper=>[$^X,'-e',$code,'a','b']);
emit({second=>$b->{done},changed=>$b->{'cmd.changed'},same_display=>$a->{'wrapped.cmd'} eq $b->{'wrapped.cmd'} ? 1:0,output=>slurp('out')});
ASTRA_FIXTURE_5
    is($r->{second},'now','changed wrapper arguments cause a rerun'); is($r->{output},'a|b|tail','result uses the new arguments');
};

subtest 'F05: changed local thread configuration invalidates output' => sub {
    my $r=fixture(<<'ASTRA_FIXTURE_6');

my $cmd=[$^X,'-e',q{open my $f,'>','out' or die $!; print {$f} $ENV{SIMPLEFLOW_THREADS}}];
my $a=task(cmd=>$cmd,threads=>1,'output.file'=>'out','stale.cmd'=>1,quiet=>1);
my $b=task(cmd=>$cmd,threads=>2,'output.file'=>'out','stale.cmd'=>1,quiet=>1);
emit({first=>$a->{done},second=>$b->{done},changed=>$b->{'cmd.changed'},output=>slurp('out')});
ASTRA_FIXTURE_6
    is($r->{second},'now','changed execution environment causes a rerun'); is($r->{output},'2','command receives the new value');
};

subtest 'F06: locking accepts a Unicode output path' => sub {
    my $r=fixture(<<'ASTRA_FIXTURE_7');

my $name="result-\x{3bb}.txt";
spew($name,'data');
my $r=eval { task(cmd=>[$^X,'-e','exit 0'],'output.file'=>$name,lock=>1,quiet=>1) };
my $e=$@; $e=~s/\n.*//s;
emit({error=>$e,done=>defined $r ? $r->{done}:undef});
ASTRA_FIXTURE_7
    is($r->{error},'','no digest error'); is($r->{done},'before','existing result can be skipped normally');
};

subtest 'F07: redirected stdout retains every attempt' => sub {
    my $r=fixture(<<'ASTRA_FIXTURE_8');

my $code=q{my $second=-e 'attempt'; open my $f,'>','attempt' or die $!; close $f; print $second ? "second\n" : "first\n"; exit($second ? 0 : 1)};
my $r=task(cmd=>[$^X,'-e',$code],'stdout.file'=>'out','output.file'=>'out',retries=>1,quiet=>1);
emit({done=>$r->{'will.do'},attempts=>$r->{attempts},out=>slurp('out'),failed=>slurp('out.failed')});
ASTRA_FIXTURE_8
    is($r->{attempts},2,'retry succeeded'); is($r->{out},"first\nsecond\n",'documented combined stream has both attempts');
};

subtest 'F08: redirected stderr remains available to the failure message' => sub {
    my $r=fixture(<<'ASTRA_FIXTURE_9');

spew('fail.pl',q{print STDERR "fixture diagnostic\n"; exit 7});
my $r=eval { task(cmd=>[$^X,'fail.pl'],'stderr.file'=>'err','output.file'=>'err',quiet=>1) };
my $e=$@;
emit({diagnostic_in_error=>index($e,'fixture diagnostic')>=0 ? 1:0,failed=>slurp('err.failed'),original_exists=>-e 'err' ? 1:0});
ASTRA_FIXTURE_9
    is($r->{diagnostic_in_error},1,'failure message contains the actual diagnostic');
};

subtest 'F09: a scalar STDIN survives a task' => sub {
    my $r=fixture(<<'ASTRA_FIXTURE_10');

my $input="first\nsecond\n";
close STDIN;
open STDIN,'<',\$input or die $!;
my $r=eval { task(cmd=>[$^X,'-e','exit 0'],quiet=>1) };
my $e=$@; $e=~s/\n.*//s;
emit({error=>$e,remaining=>scalar <STDIN>});
ASTRA_FIXTURE_10
    is($r->{error},'','task returns normally'); is($r->{remaining},"first\n",'caller can still read its input');
};

done_testing;
