use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More;

use xCAT::DHCP::Backend;

is( xCAT::DHCP::Backend->normalize(undef), 'auto', 'undefined backend defaults to auto' );
is( xCAT::DHCP::Backend->normalize(' ISC '), 'isc', 'backend values are trimmed and lowercased' );
is( xCAT::DHCP::Backend->normalize('kea'), 'kea', 'kea is valid' );
is( xCAT::DHCP::Backend->normalize('bogus'), undef, 'invalid backend is rejected' );

# auto: ISC when its server is installed, Kea otherwise, whatever the platform.
my @auto = (
    [ 'el9 with ISC',                 { platform => 'el9',  os => 'rhel9' },        { isc => 1, kea => 0 }, 'isc' ],
    [ 'el10 with only Kea',           { platform => 'el10', os => 'rhel10' },       { isc => 0, kea => 1 }, 'kea' ],
    [ 'el10 with ISC installed',      { platform => 'el10', os => 'rhel10' },       { isc => 1, kea => 1 }, 'isc' ],
    [ 'ubuntu24.04 with both',        { os_name => 'ubuntu', version => '24.04' },  { isc => 1, kea => 1 }, 'isc' ],
    [ 'ubuntu22.04 with only ISC',    { os_name => 'ubuntu', version => '22.04' },  { isc => 1, kea => 0 }, 'isc' ],
    [ 'ubuntu26.04 with only Kea',    { os_name => 'ubuntu', version => '26.04' },  { isc => 0, kea => 1 }, 'kea' ],
    [ 'ubuntu20.04 with only Kea',    { os_name => 'ubuntu', version => '20.04' },  { isc => 0, kea => 1 }, 'kea' ],
    [ 'sles15 with ISC',              { os_name => 'sles', version => 15 },         { isc => 1, kea => 0 }, 'isc' ],
);

for my $case (@auto) {
    my ( $label, $platform, $available, $want ) = @$case;

    is( xCAT::DHCP::Backend->default_backend( %$platform, available => $available ),
        $want, "default_backend: $label selects $want" );

    my $sel = xCAT::DHCP::Backend->choose(
        requested       => 'auto',
        check_available => 1,
        available       => $available,
        %$platform,
    );
    ok( !$sel->{error}, "choose auto: $label has no error" );
    is( $sel->{name}, $want, "choose auto: $label selects $want" );
    is( $sel->{requested}, 'auto', "choose auto: $label keeps the request as auto" );
}

like(
    xCAT::DHCP::Backend->choose(
        requested       => 'auto',
        check_available => 1,
        available       => { isc => 0, kea => 0 },
    )->{error},
    qr/No DHCP server is installed/,
    'auto with no DHCP server installed names the missing servers'
);

# An explicit backend is not changed by what is installed, and fails hard when absent.
is(
    xCAT::DHCP::Backend->choose( requested => 'kea', available => { isc => 1, kea => 1 } )->{name},
    'kea',
    'explicit Kea wins when ISC is installed'
);

is(
    xCAT::DHCP::Backend->choose( requested => 'isc', available => { isc => 0, kea => 1 } )->{name},
    'isc',
    'explicit ISC is kept without check_available'
);

like(
    xCAT::DHCP::Backend->choose(
        requested       => 'kea',
        check_available => 1,
        available       => { isc => 1, kea => 0 },
    )->{error},
    qr/The selected DHCP backend 'kea' is not available/,
    'explicit Kea that is not installed is a hard error'
);

like(
    xCAT::DHCP::Backend->choose(
        requested       => 'isc',
        check_available => 1,
        available       => { isc => 0, kea => 1 },
    )->{error},
    qr/The selected DHCP backend 'isc' is not available/,
    'explicit ISC that is not installed is a hard error'
);

like(
    xCAT::DHCP::Backend->choose( requested => 'invalid' )->{error},
    qr/Invalid site\.dhcpbackend/,
    'invalid explicit backend returns a clear error'
);

{
    my $backend = xCAT::DHCP::Backend->new_backend(
        requested       => 'auto',
        check_available => 1,
        available       => { isc => 1, kea => 1 },
    );
    isa_ok( $backend, 'xCAT::DHCP::Backend::ISC', 'new_backend for auto with both installed' );
}

{
    my $backend = xCAT::DHCP::Backend->new_backend(
        requested       => 'auto',
        check_available => 1,
        available       => { isc => 0, kea => 1 },
    );
    isa_ok( $backend, 'xCAT::DHCP::Backend::Kea', 'new_backend for auto with only Kea' );
}

{
    local $ENV{PATH} = '';
    ok(
        xCAT::DHCP::Backend::_command_exists('sh'),
        'backend availability retains the standard system-directory fallback'
    );
}

done_testing();
