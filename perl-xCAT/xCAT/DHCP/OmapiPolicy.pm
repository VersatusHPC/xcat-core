package xCAT::DHCP::OmapiPolicy;

use strict;
use warnings;

use xCAT::StringUtils qw(trim);

my %ALGORITHMS = (
    'hmac-md5'    => 157,
    'hmac-sha1'   => 161,
    'hmac-sha224' => 162,
    'hmac-sha256' => 163,
    'hmac-sha384' => 164,
    'hmac-sha512' => 165,
);

# The order of the HMAC algorithms, weakest first. A stanza an administrator made
# stronger must survive a default that is weaker.
my %STRENGTH = (
    'hmac-md5'    => 0,
    'hmac-sha1'   => 1,
    'hmac-sha224' => 2,
    'hmac-sha256' => 3,
    'hmac-sha384' => 4,
    'hmac-sha512' => 5,
);

sub settings {
    my ( $class, %args ) = @_;

    my $raw_algorithm      = _site_value( 'dhcpomapialgorithm', %args );
    my $algorithm_explicit = defined($raw_algorithm) && $raw_algorithm ne '';

    # named.conf and dhcpd.conf declare one key name. Both writers resolve the algorithm
    # from this policy, so the default must not depend on which file the caller read.
    unless ($algorithm_explicit) {
        $raw_algorithm = $class->default_algorithm(%args);

        # A deployed stanza can only raise the default, never lower it. A rule that lets a
        # deployed hmac-md5 win pulls one writer back down while the other moves up.
        my $deployed = $class->known_algorithm( $args{deployed_algorithm} );
        $raw_algorithm = $deployed
          if defined($deployed)
          && $STRENGTH{$deployed} > $STRENGTH{$raw_algorithm};
    }

    my $algorithm = $class->normalize_algorithm($raw_algorithm);
    unless ($algorithm) {
        return {
            error => "Invalid site.dhcpomapialgorithm value '$raw_algorithm'. Valid values are: "
              . join( ', ', sort keys %ALGORITHMS )
              . ".",
        };
    }

    my $raw_key_name = _site_value( 'dhcpomapikeyname', %args );
    my $key_name     = $class->normalize_key_name($raw_key_name);
    unless ($key_name) {
        return {
            error => "Invalid site.dhcpomapikeyname value '$raw_key_name'. Use letters, digits, underscore, dot, or dash.",
        };
    }

    my $raw_omshell_path = _site_value( 'dhcpomshellpath', %args );
    my $omshell_path     = $class->normalize_omshell_path($raw_omshell_path);
    unless ($omshell_path) {
        return {
            error => "Invalid site.dhcpomshellpath value '$raw_omshell_path'. Use an absolute path without whitespace.",
        };
    }

    return {
        algorithm                   => $algorithm,
        algorithm_explicit          => $algorithm_explicit,
        key_name                    => $key_name,
        key_name_for_regex          => quotemeta($key_name),
        key_rr_type                 => $ALGORITHMS{$algorithm},
        omshell_path                => $omshell_path,
        needs_omshell_key_algorithm => $algorithm ne 'hmac-md5',
    };
}

sub normalize_algorithm {
    my ( $class, $algorithm ) = @_;

    # hmac-md5 is not approved for FIPS mode. named starts with no complaint about an
    # md5 key stanza and then answers SERVFAIL to every update signed with that key.
    return 'hmac-sha256' unless defined($algorithm) && $algorithm ne '';
    return $class->known_algorithm($algorithm);
}

sub known_algorithm {
    my ( $class, $algorithm ) = @_;

    return unless defined($algorithm) && $algorithm ne '';
    $algorithm = lc( trim($algorithm) );

    return $algorithm if $ALGORITHMS{$algorithm};
    return;
}

sub default_algorithm {
    my ( $class, %args ) = @_;

    # xCAT does not manage an external DNS server and cannot rekey one. That server holds
    # the hmac-md5 key xCAT signed with before, and dhcpd updates the same server.
    my $external = exists( $args{external} )
      ? $args{external}
      : _site_value( 'externaldns', %args );
    return 'hmac-md5' if $external;

    return 'hmac-md5' if $class->omshell_pinned_to_md5(%args);
    return 'hmac-sha256';
}

sub algorithm_rr_type {
    my ( $class, $algorithm ) = @_;

    $algorithm = $class->normalize_algorithm($algorithm) or return;
    return $ALGORITHMS{$algorithm};
}

sub algorithm_strength {
    my ( $class, $algorithm ) = @_;

    $algorithm = $class->normalize_algorithm($algorithm) or return;
    return $STRENGTH{$algorithm};
}

sub keeps_deployed_algorithm {
    my ( $class, $settings, $deployed ) = @_;

    # A stanza with no algorithm line names no algorithm to keep. Repair it.
    $deployed = $class->known_algorithm($deployed) or return 0;
    return $deployed eq $settings->{algorithm} if $settings->{algorithm_explicit};

    return $class->algorithm_strength($deployed) >=
      $class->algorithm_strength( $settings->{algorithm} ) ? 1 : 0;
}

sub new_install_default_algorithm {
    my ( $class, %args ) = @_;

    return unless $args{is_new_install};
    return 'hmac-sha256' if $class->omshell_takes_key_algorithm(%args);

    # The site table pins hmac-md5 for a platform whose omshell cannot name an algorithm.
    # Without the entry the installation would take the hmac-sha256 default and its OMAPI
    # would authenticate against the wrong algorithm.
    return 'hmac-md5';
}

sub omshell_pinned_to_md5 {
    my ( $class, %args ) = @_;

    my ( $platform, $os ) = $class->_platform_and_os(%args);

    # The omshell of SLES 12, SLES 15, openSUSE Leap 15 and Ubuntu 18.04 has no
    # key-algorithm command, so it authenticates only against an hmac-md5 OMAPI key.
    # A platform this routine does not recognise takes the hmac-sha256 default.
    return 1 if defined($os) && $os =~ /^(?:sles|opensuse[a-z-]*)\b/i;
    if ( defined($os) && $os =~ /^ubuntu,(\d+\.\d+(?:\.\d+)*)\b/i ) {
        my $ubuntu_version = $1;
        require xCAT::Utils;
        return 1 if xCAT::Utils->version_cmp( $ubuntu_version, '20.04' ) < 0;
    }
    return 0;
}

sub _platform_and_os {
    my ( $class, %args ) = @_;

    return ( $args{platform}, $args{os} )
      if defined( $args{platform} ) || defined( $args{os} );

    # Both writers must read the platform the same way, or they pin different algorithms.
    my ( $platform, $os );
    eval {
        require xCAT::Utils;
        $platform = xCAT::Utils->osver('platform');
        $os       = xCAT::Utils->osver('all');
        1;
    };
    return ( $platform, $os );
}

sub omshell_takes_key_algorithm {
    my ( $class, %args ) = @_;

    my $platform = $args{platform};
    my $os       = $args{os};

    # The omshell of dhcp-server-4.3.6-50.el8_10 accepts key-algorithm and cannot
    # authenticate against a hmac-sha256 OMAPI key without it.
    return 1
      if defined($platform) && $platform =~ /^el(\d+)\b/i && $1 >= 8;
    if ( defined($os) && $os =~ /^ubuntu,(\d+\.\d+(?:\.\d+)*)\b/i ) {
        my $ubuntu_version = $1;
        require xCAT::Utils;
        return 1
          if xCAT::Utils->version_cmp( $ubuntu_version, '20.04' ) >= 0;
    }
    return 0;
}

sub normalize_key_name {
    my ( $class, $key_name ) = @_;

    $key_name = 'xcat_key' unless defined($key_name) && $key_name ne '';
    $key_name = trim($key_name);

    return $key_name if $key_name =~ /\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/;
    return;
}

sub normalize_omshell_path {
    my ( $class, $path ) = @_;

    $path = '/usr/bin/omshell' unless defined($path) && $path ne '';
    $path = trim($path);

    return $path if $path =~ m{\A/[A-Za-z0-9_.:/%+=@-]+\z};
    return;
}

sub key_owner {
    my ( $class, $settings ) = @_;

    my $owner = $settings->{key_name};
    $owner .= '.' unless $owner =~ /\.\z/;
    return $owner;
}

sub omshell_preamble {
    my ( $class, $settings, %args ) = @_;

    my $secret   = $args{secret};
    my $commands = '';
    $commands .= "port $args{port}\n" if defined $args{port};

    # Stock legacy omshell accepts the implicit MD5 default but rejects an
    # explicit key-algorithm command, so emit it only when needed.
    $commands .= "key-algorithm $settings->{algorithm}\n"
      if $settings->{needs_omshell_key_algorithm};
    $commands .= "key $settings->{key_name} \"$secret\"\n";
    $commands .= "server $args{server}\n"
      if defined( $args{server} ) && $args{server} ne '';
    return $commands;
}

sub _site_value {
    my ( $key, %args ) = @_;

    if ( ref( $args{site_values} ) eq 'HASH'
        && exists $args{site_values}{$key} )
    {
        return $args{site_values}{$key};
    }

    return $::XCATSITEVALS{$key} if exists $::XCATSITEVALS{$key};

    my $value = eval {
        require xCAT::TableUtils;
        my @entries = xCAT::TableUtils->get_site_attribute($key);
        return $entries[0];
    };

    return $value;
}

1;
