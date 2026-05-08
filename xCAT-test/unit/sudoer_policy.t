#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../../perl-xCAT";

use Test::More;

use xCAT::SudoerPolicy qw(
  LEGACY_USERNAME
  LEGACY_PASSWORD
  DEFAULT_SUDOER_POLICY
  resolve_sudoer_policy
  sudoer_policy_warnings
  is_valid_sudoer_username
);

is(DEFAULT_SUDOER_POLICY, 'legacy', 'legacy policy is the default for backward compatibility');
is(LEGACY_USERNAME, 'xcat', 'legacy username is xcat');
is(LEGACY_PASSWORD, 'rootpw', 'legacy password is rootpw (for deprecation warning)');

my $default = resolve_sudoer_policy({});
is($default->{policy}, 'legacy', 'empty site settings use legacy policy');
is($default->{source}, 'default', 'empty site settings are reported as default source');

my $legacy = resolve_sudoer_policy({ sudoerpolicy => ' Legacy ' });
is($legacy->{policy}, 'legacy', 'legacy policy is case and whitespace tolerant');
is($legacy->{source}, 'sudoerpolicy', 'explicit legacy policy is reported as site policy source');

my $modern = resolve_sudoer_policy({ sudoerpolicy => 'modern' });
is($modern->{policy}, 'modern', 'modern policy is accepted');
is($modern->{source}, 'sudoerpolicy', 'modern policy source is reported correctly');

my $disabled = resolve_sudoer_policy({ sudoerpolicy => 'disabled' });
is($disabled->{policy}, 'disabled', 'disabled policy is accepted');

my $invalid = resolve_sudoer_policy({ sudoerpolicy => 'bogus' });
is($invalid->{policy}, 'invalid', 'invalid policy returns invalid (fail closed)');
is($invalid->{source}, 'sudoerpolicy', 'invalid policy source is sudoerpolicy');
ok(defined $invalid->{error}, 'invalid policy includes error message');

my @bad_policy = sudoer_policy_warnings({ sudoerpolicy => 'bogus' });
like($bad_policy[0], qr/Unsupported site\.sudoerpolicy/, 'invalid policy produces a warning');
like($bad_policy[0], qr/will fail/, 'warning indicates failure not fallback');

my @legacy_warnings = sudoer_policy_warnings({});
like($legacy_warnings[0], qr/hardcoded credentials/, 'default legacy mode produces deprecation warning');

my @explicit_legacy_warnings = sudoer_policy_warnings({ sudoerpolicy => 'legacy' });
like($explicit_legacy_warnings[0], qr/hardcoded credentials/, 'explicit legacy mode produces deprecation warning');

my @modern_warnings = sudoer_policy_warnings({ sudoerpolicy => 'modern' });
is(scalar @modern_warnings, 0, 'modern policy does not produce warnings');

my @disabled_warnings = sudoer_policy_warnings({ sudoerpolicy => 'disabled' });
is(scalar @disabled_warnings, 0, 'disabled policy does not produce warnings');

ok(is_valid_sudoer_username('xcat'), 'xcat is a valid username');
ok(is_valid_sudoer_username('admin'), 'admin is a valid username');
ok(is_valid_sudoer_username('xcat_admin'), 'underscores allowed');
ok(is_valid_sudoer_username('xcat-admin'), 'hyphens allowed');
ok(!is_valid_sudoer_username('root'), 'root is protected');
ok(!is_valid_sudoer_username('bin'), 'bin is protected');
ok(!is_valid_sudoer_username('nobody'), 'nobody is protected');
ok(!is_valid_sudoer_username(''), 'empty string rejected');
ok(!is_valid_sudoer_username('ops.team'), 'dots not allowed');
ok(!is_valid_sudoer_username('user name'), 'spaces not allowed');
ok(!is_valid_sudoer_username("user'name"), 'quotes not allowed');

done_testing();
