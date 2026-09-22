#!/usr/bin/env perl
# The genesis spec names its BuildRequires with EL package names, and buildrpms.pl translates
# them for a SUSE chroot. One clone builds more than one target: the SUSE dep pipeline builds
# sles15 and then sles12, and a single run forks a child per (package, target) pair. So the
# translation for one target must not depend on what another target did before it. When it did,
# the Leap 42.3 build asked for net-tools-deprecated -- a name only Leap 15 has -- and the
# buildroot install failed before %build.
#
# buildrpms.pl cannot be loaded: it runs mkdir/git/read_text at file scope and expects a working
# tree. The routines are lifted out with a regex and eval'd into a scratch package with their
# collaborators supplied, per the repo's code standard.
use strict;
use warnings;

use Cwd qw(getcwd);
use File::Path qw(make_path);
use File::Slurper qw(read_text write_text);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More tests => 10;

use XCAT::Test::File qw(repo_path);

my $builder = repo_path('buildrpms.pl');
die "buildrpms.pl is not readable at $builder" unless -r $builder;
my $source = read_text($builder);

my $spec_source = repo_path('xCAT-genesis-builder/xCAT-genesis-base.spec');
die "the genesis spec is not readable at $spec_source" unless -r $spec_source;
my $SPEC_TEXT = read_text($spec_source);

# ---------------------------------------------------------------- extraction --
# die, not BAIL_OUT: a bail-out stops every other file prove would run, and an extraction that
# stops matching must fail loudly here and nowhere else.
my @required = qw(is_suse_target genesis_buildrequires_map buildsources_genesis_base);
my @optional = qw(genesis_spec_path genesis_spec_source rewrite_genesis_buildrequires);
my @lifted;
for my $name (@required, @optional) {
    my ($body) = $source =~ /\n(sub \Q$name\E\b.*?\n\})\n/s;
    die "could not extract $name from buildrpms.pl" if !$body && grep { $_ eq $name } @required;
    push @lifted, $body if $body;
}

my $harness = join "\n",
    'package Scratch;',
    'use strict; use warnings;',
    'use File::Basename qw(dirname);',
    'use File::Copy qw(cp);',
    'use File::Path qw(make_path remove_tree);',
    'use File::Slurper qw(read_text write_text);',
    'our ($SOURCES, $SOURCE_DATE_EPOCH);',
    'sub sh_or_die { my ($cmd, $message) = @_; system($cmd) == 0 or die "$message\n"; }',
    @lifted,
    '1;';
eval $harness or die "could not evaluate the extracted routines: $@";

# A tree that rewrites the tracked spec in place has no genesis_spec_path, and hands mock that
# file. Name it here so the test reads the spec the build reads, whichever tree it runs on.
unless (defined &Scratch::genesis_spec_path) {
    no warnings 'once';
    *Scratch::genesis_spec_path = sub { 'xCAT-genesis-builder/xCAT-genesis-base.spec' };
}

{
    no warnings 'once';
    $Scratch::SOURCES = tempdir(CLEANUP => 1);
    $Scratch::SOURCE_DATE_EPOCH = 0;
}

my $LEAP15 = 'opensuse-leap-15.6-x86_64';
my $LEAP42 = 'opensuse-leap-42.3-x86_64';
my $EL     = 'alma+epel-10-x86_64';

# ------------------------------------------------------------------- harness --
sub fresh_tree {
    my $root = tempdir(CLEANUP => 1);
    my $builder_dir = "$root/xCAT-genesis-builder";
    make_path("$builder_dir/dracut_105");
    write_text("$builder_dir/xCAT-genesis-base.spec", $SPEC_TEXT);
    write_text("$builder_dir/80-net-name-slot.rules", "# net name slot rules\n");
    write_text("$builder_dir/verify-genesis-payload", "#!/bin/sh\nexit 0\n");
    write_text("$builder_dir/dracut_105/module-setup.sh", "#!/bin/sh\nexit 0\n");
    return $root;
}

# buildsources_genesis_base reads and writes relative to the checkout, so run it there.
sub run_pass {
    my ($root, @targets) = @_;
    my $cwd = getcwd();
    chdir $root or die "cannot chdir to $root: $!";
    my $ok = eval { Scratch::buildsources_genesis_base($_) for @targets; 1 };
    my $error = $@;
    chdir $cwd or die "cannot chdir back to $cwd: $!";
    die "buildsources_genesis_base(@targets) died: $error" unless $ok;
    return $root;
}

# The spec mock is given for this target, as a list of the packages it asks for.
sub buildrequires {
    my ($root, $target) = @_;
    my $path = Scratch::genesis_spec_path($target);
    $path = File::Spec->catfile($root, $path) unless File::Spec->file_name_is_absolute($path);
    my $text = read_text($path);
    return [ $text =~ /^BuildRequires:\s+(\S+)\s*$/mg ];
}

sub tracked_spec {
    my ($root) = @_;
    return read_text("$root/xCAT-genesis-builder/xCAT-genesis-base.spec");
}

my $fresh15 = buildrequires(run_pass(fresh_tree(), $LEAP15), $LEAP15);
my $fresh42 = buildrequires(run_pass(fresh_tree(), $LEAP42), $LEAP42);

# --------------------------------------------------------- the two translations --
ok(  grep({ $_ eq 'net-tools-deprecated' } @{$fresh15}),
    'Leap 15.6 asks for net-tools-deprecated, where netstat lives');
ok(  grep({ $_ eq 'net-tools' } @{$fresh42}),
    'Leap 42.3 asks for net-tools, which it never split');

# ------------------------------------------------------ one clone, two targets --
{
    my $root = run_pass(fresh_tree(), $LEAP15, $LEAP42);
    my $second = buildrequires($root, $LEAP42);

    is_deeply($second, $fresh42,
        'Leap 42.3 after Leap 15.6 asks for what Leap 42.3 alone asks for');
    ok( !grep({ $_ eq 'net-tools-deprecated' } @{$second}),
        'and never for net-tools-deprecated, which Leap 42.3 has no package for');
    ok(  grep({ $_ eq 'net-tools' } @{$second}),
        'and still for net-tools');
}

{
    my $root = run_pass(fresh_tree(), $LEAP42, $LEAP15);
    is_deeply(buildrequires($root, $LEAP15), $fresh15,
        'the leak runs the other way too: Leap 15.6 after Leap 42.3 is unchanged');
}

{
    my $root = run_pass(fresh_tree(), $LEAP42, $LEAP15, $LEAP42);
    is_deeply(buildrequires($root, $LEAP42), $fresh42,
        'a third pass reads the spec, not the second pass');
}

# ------------------------------------------------------------ the EL targets --
# An EL target in the same clone must not inherit SUSE names either.
{
    my $root = run_pass(fresh_tree(), $EL);
    is_deeply(buildrequires($root, $EL), [ $SPEC_TEXT =~ /^BuildRequires:\s+(\S+)\s*$/mg ],
        'an EL target builds the spec as it is written');
}
{
    my $root = run_pass(fresh_tree(), $LEAP15, $EL);
    is_deeply(buildrequires($root, $EL), [ $SPEC_TEXT =~ /^BuildRequires:\s+(\S+)\s*$/mg ],
        'an EL target after a SUSE target still builds the spec as it is written');
}

# ---------------------------------------------------------------- provenance --
# The spec is tracked. A build that edits it leaves the checkout dirty, and two children of one
# run write the file at the same time.
{
    my $root = run_pass(fresh_tree(), $LEAP15, $LEAP42);
    is(tracked_spec($root), $SPEC_TEXT,
        'the build leaves the tracked spec as git has it');
}
