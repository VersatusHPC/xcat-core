#!/usr/bin/env perl
# ppc64el diskful install: the pre-install script mkinstall picks, and the document
# Subiquity's early-command builds from it.
#
# mkinstall selected pre.ubuntu.ppc64 for every Ubuntu ppc64el install, Subiquity or not.
# That file is a debian-installer early_command: it writes a partman-auto recipe. The
# Subiquity early-command appends the file it writes to /autoinstall.yaml, so Subiquity
# read the recipe as YAML and stopped with "could not find expected ':'".
#
# Both halves are asserted by execution, not by a regex over the source: mkinstall's own
# selection is lifted out and driven, and the partitioning block is run and its output
# assembled into the document exactly as the early-command assembles it, then parsed.
use strict;
use warnings;

use File::Spec;
use File::Temp ();
use FindBin;
use JSON::PP ();
use Test::More;

my $repo_root = File::Spec->rel2abs( File::Spec->catdir( $FindBin::Bin, '..', '..' ) );
my $plugin = File::Spec->catfile( $repo_root, 'xCAT-server', 'lib', 'xcat', 'plugins', 'debian.pm' );
my $pre    = File::Spec->catfile( $repo_root, 'xCAT-server', 'share', 'xcat', 'install', 'scripts', 'pre.ubuntu.subiquity' );
my $tmpl   = File::Spec->catfile( $repo_root, 'xCAT-server', 'share', 'xcat', 'install', 'ubuntu', 'compute.subiquity.tmpl' );

plan skip_all => "debian.pm not found"                  unless -f $plugin;
plan skip_all => "pre.ubuntu.subiquity not found"       unless -f $pre;
plan skip_all => "compute.subiquity.tmpl not found"     unless -f $tmpl;

sub slurp { my ($p) = @_; open my $fh, '<', $p or die "$p: $!"; local $/; return <$fh>; }

my $src    = slurp($plugin);
my $script = slurp($pre);

# ------------------------------------------------------------ which script mkinstall picks --
# The selection statements are lifted out of mkinstall and driven. mkinstall itself needs a
# management node and a database, so the block cannot be called directly; taking the block
# keeps the code under test identical to the code that runs.
my ($selection) = $src =~ /\n([ ]+my \$prescript = "\$::XCATROOT\/share\/xcat\/install\/scripts\/pre\.\$platform";.*?)\n[ ]+if \(-r "\$prescript"\) \{/s;
ok( defined $selection, 'the prescript selection is still where mkinstall keeps it' );

my ($subiquity_sub) = $src =~ /\n(sub using_subiquity\b.*?\n\})\n/s;
ok( defined $subiquity_sub, 'using_subiquity is still a named sub in debian.pm' );

my $picked_ok = 0;
SKIP: {
    skip 'the prescript selection could not be lifted out of mkinstall', 6
        unless defined $selection && defined $subiquity_sub;

    # An implausibly large slice means the match ran past the block and the driver below
    # would be exercising something else.
    ok( ( $selection =~ tr/\n// ) <= 20, 'the lifted selection is the block, not the rest of mkinstall' );
    ok( $selection =~ /using_subiquity\(/, 'and it is the block that asks whether Subiquity is in use' );

    my $driver = <<"CODE";
\$::XCATROOT = '/opt/xcat';
$subiquity_sub
sub pick {
    my (\$platform, \$arch, \$os, \$tmplfile) = \@_;
$selection
    return \$prescript;
}
CODE

    {
        package PICK;
        eval "$driver; 1" or main::diag("could not eval the selection: $@");
    }

    my $subiquity_tmpl = '/opt/xcat/share/xcat/install/ubuntu/compute.subiquity.tmpl';
    my $di_tmpl        = '/opt/xcat/share/xcat/install/ubuntu/compute.tmpl';

    is( PICK::pick( 'ubuntu', 'ppc64el', 'ubuntu24.04', $subiquity_tmpl ),
        '/opt/xcat/share/xcat/install/scripts/pre.ubuntu.subiquity',
        'a Subiquity ppc64el install gets the Subiquity pre-install script' );
    is( PICK::pick( 'ubuntu', 'ppc64le', 'ubuntu22.04', $subiquity_tmpl ),
        '/opt/xcat/share/xcat/install/scripts/pre.ubuntu.subiquity',
        'and so does one whose arch is spelled ppc64le' );
    is( PICK::pick( 'ubuntu', 'ppc64el', 'ubuntu18.04', $di_tmpl ),
        '/opt/xcat/share/xcat/install/scripts/pre.ubuntu.ppc64',
        'a debian-installer ppc64el install still gets the partman recipe' );
    is( PICK::pick( 'ubuntu', 'x86_64', 'ubuntu24.04', $subiquity_tmpl ),
        '/opt/xcat/share/xcat/install/scripts/pre.ubuntu.subiquity',
        'x86_64 is unchanged' );
    $picked_ok = 1;
}

# mkinstall renders the script only when it is readable, so a rename would leave the node
# with no pre-install script and no error.
ok( -r $pre, 'the script the ppc64el choice names is readable' );

# ------------------------------------------------------- the partitioning the script writes --
# The block is executed rather than matched. `[` and `uname` are shadowed so both the
# firmware test and the architecture test run unmodified: bash resolves a function ahead of
# the builtin, and the shadow delegates every other test to the real builtin.
my ($storage_block) = $script =~ /(^XCAT_ARCH=.*?\n^fi$)/ms;
ok( defined $storage_block,
    'the prescript reads the machine architecture before it chooses a partitioning layout' );

my $sandbox  = File::Temp::tempdir( CLEANUP => 1 );
my $partfile = File::Spec->catfile( $sandbox, 'partitionfile' );

sub partition_file_for {
    my ( $efi_rc, $machine ) = @_;
    my $block = $storage_block;
    my $rewrites = ( $block =~ s{/tmp/partitionfile}{$partfile}g );
    return ( undef, "expected three partition-file redirects, rewrote $rewrites" )
        unless $rewrites == 3;

    my $runner = File::Spec->catfile( $sandbox, 'storage.sh' );
    open my $fh, '>', $runner or die "$runner: $!";
    print {$fh} <<"SHELL";
INSTALL_DISK=/dev/vda
logger() { :; }
uname() { builtin echo $machine; }
[() {
  case "\$1 \$2" in
    "-d /sys/firmware/efi") return $efi_rc ;;
  esac
  set -- "\${\@:1:\$((\$#-1))}"
  builtin test "\$\@"
}
$block
SHELL
    close $fh;

    unlink $partfile;
    system( 'bash', $runner ) == 0
        or return ( undef, "the partitioning block failed to run for $machine" );
    return ( undef, "the partitioning block wrote no file for $machine" ) unless -s $partfile;
    return ( slurp($partfile), undef );
}

# ------------------------------------------------------------------ the assembled document --
# The template's markers are substituted before the document is parsed. An unsubstituted
# marker is a YAML comment, so leaving one in would silently remove the key it belongs to.
my %MARKER = (
    'HOSTNAME'                                                 => 'cn1',
    'XCATVAR:XCATMASTER'                                       => '10.0.0.1',
    'COLONHTTPPORT'                                            => ':80',
    'CRYPTORLOCKED:passwd:key=system,username=root:password'   => '$6$salt$hash',
    'TABLE:site:key=timezone:value'                            => 'UTC',
    'TABLE:site:key=domain:value'                              => 'cluster',
    'TABLE:noderes:$NODE:xcatmaster'                           => 'mn.cluster',
    'TABLEBLANKOKAY:bootparams:$NODE:kcmdline'                 => 'console=hvc0',
    'TABLEBLANKOKAY:site:key=xcatiport:value'                  => '3002',
    'SUBIQUITYINSTALLNIC'                                      => 'enp0s2',
    'SUBIQUITYINSTALLMAC'                                      => '52:54:00:00:00:01',
    'UBUNTU_SUBIQUITY_APT_CONFIG'                              => join( "\n",
        '  apt:',
        '    preserve_sources_list: false',
        '    geoip: false',
        '    mirror-selection:',
        '      primary:',
        '      - uri: http://ports.ubuntu.com/ubuntu-ports' ),
);

my $rendered = slurp($tmpl);
my @unknown;
$rendered =~ s{\#([A-Z][A-Z0-9_]*(?::[^\#\s]*)?)\#}{
    exists $MARKER{$1} ? $MARKER{$1} : do { push @unknown, $1; "#$1#" }
}ge;
is( scalar @unknown, 0, 'every template marker has a value in this test' )
    or diag( "unsubstituted: @unknown" );

my $assemble = File::Spec->catfile( $sandbox, 'assemble.py' );
open my $py, '>', $assemble or die "$assemble: $!";
print {$py} <<'PY';
import json, re, sys, yaml

rendered, partition = sys.argv[1], sys.argv[2]

# Subiquity re-serializes /autoinstall.yaml after the first load and strips the
# autoinstall: wrapper. The early-command appends the partition file to that
# unwrapped document, so model it the same way.
doc = yaml.safe_load(open(rendered))
inner = yaml.safe_dump(doc["autoinstall"], default_flow_style=False)
inner = re.sub(r"(?m)^\.\.\.$\n?", "", inner)
combined = inner + open(partition).read()
try:
    parsed = yaml.safe_load(combined)
except yaml.YAMLError as err:
    print(json.dumps({"error": str(err)}))
    sys.exit(0)
print(json.dumps({"parsed": parsed}))
PY
close $py;

sub assemble_for {
    my ( $efi_rc, $machine ) = @_;
    my ( $partition, $why ) = partition_file_for( $efi_rc, $machine );
    return { error => $why } unless defined $partition;
    my $doc = File::Spec->catfile( $sandbox, 'autoinstall.yaml' );
    open my $fh, '>', $doc or die "$doc: $!";
    print {$fh} $rendered;
    close $fh;
    my $out = qx{python3 "$assemble" "$doc" "$partfile" 2>&1};
    return { error => "python3 could not assemble the document: $out" } if $?;
    my $decoded = eval { JSON::PP->new->decode($out) };
    return { error => "unreadable assembler output: $out" } unless $decoded;
    return $decoded;
}

SKIP: {
    skip 'the partitioning block could not be lifted out of the prescript', 14
        unless defined $storage_block;

    my $ppc = assemble_for( 1, 'ppc64le' );
    ok( !$ppc->{error}, 'a ppc64el autoinstall document parses as YAML' )
        or diag( $ppc->{error} );

    SKIP: {
        skip 'the ppc64el document did not parse', 13 if $ppc->{error};
        my $doc = $ppc->{parsed};

        # The append must not destroy what the template put in the document.
        ok( ref $doc eq 'HASH', 'the assembled document is a mapping' );
        is( $doc->{version}, 1, 'the autoinstall version survives the append' );
        ok( ref $doc->{'early-commands'} eq 'ARRAY', 'and the early-commands survive it' );
        is( $doc->{identity}{hostname}, 'cn1', 'and the identity block' );

        my $storage = $doc->{storage};
        is( ref $storage, 'HASH', 'the appended storage section is a mapping' );
        is( $storage->{version}, 1, 'declaring curtin storage version 1' );

        my %by_id = map { $_->{id} => $_ } @{ $storage->{config} || [] };

        # A PReP partition is what OpenFirmware loads grub from on ppc64el. curtin creates
        # one for flag: prep, and installs grub to the partition tagged grub_device.
        my ($prep) = grep { ( $_->{flag} || '' ) eq 'prep' } values %by_id;
        ok( $prep, 'ppc64el gets a PReP boot partition' );
        is( $prep && $prep->{type},        'partition',     'as a partition' );
        is( $prep && $prep->{device},      'disk-detected', 'on the install disk' );
        is( $prep && $prep->{grub_device}, JSON::PP::true,  'and grub is installed to it' );

        # A PReP partition holds the boot image itself. Formatting or mounting it would
        # overwrite what grub writes there.
        my $prep_id = $prep ? $prep->{id} : '';
        my @prep_formats = grep {
            ( $_->{type} || '' ) eq 'format' && ( $_->{volume} || '' ) eq $prep_id
        } values %by_id;
        is( scalar @prep_formats, 0, 'the PReP partition is not formatted' );

        my @bios_grub = grep { ( $_->{flag} || '' ) eq 'bios_grub' } values %by_id;
        is( scalar @bios_grub, 0, 'and there is no x86 bios_grub partition on it' );

        is( $by_id{'root-part-fs'}{fstype}, 'ext4', 'root is ext4' );
        is( $by_id{'root-part-mount'}{path}, '/',   'and mounted at /' );
    }
}

# The two x86 layouts go through the same assembly, so the ppc64el branch cannot be added
# by breaking them.
SKIP: {
    skip 'the partitioning block could not be lifted out of the prescript', 4
        unless defined $storage_block;

    foreach my $case ( [ 'UEFI', 0, 'x86_64', 'efi-part' ], [ 'BIOS', 1, 'x86_64', 'bios-grub' ] ) {
        my ( $name, $efi_rc, $machine, $expect ) = @{$case};
        my $out = assemble_for( $efi_rc, $machine );
        ok( !$out->{error}, "an $name autoinstall document still parses as YAML" )
            or diag( $out->{error} );
        next if $out->{error};
        my %by_id = map { $_->{id} => $_ } @{ $out->{parsed}{storage}{config} || [] };
        ok( $by_id{$expect}, "and $name still gets its $expect partition" );
    }
}

done_testing();
