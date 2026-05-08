# IBM(c) 2025 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT::SudoerPolicy;

use strict;
use warnings;

use Exporter qw(import);

our @EXPORT_OK = qw(
  LEGACY_USERNAME
  LEGACY_PASSWORD
  DEFAULT_SUDOER_POLICY
  resolve_sudoer_policy
  sudoer_policy_warnings
  is_valid_sudoer_username
);

use constant LEGACY_USERNAME => 'xcat';
use constant LEGACY_PASSWORD => 'rootpw';
use constant DEFAULT_SUDOER_POLICY => 'legacy';

sub _site_value {
    my ($site, $key) = @_;

    return '' unless $site && defined $site->{$key};

    my $value = $site->{$key};
    $value =~ s/^\s+|\s+$//g;
    return $value;
}

sub _normalize_policy {
    my $policy = shift || '';
    $policy =~ s/^\s+|\s+$//g;
    return lc($policy);
}

sub resolve_sudoer_policy {
    my $site = shift || {};

    my $policy_value = _site_value($site, 'sudoerpolicy');
    my $policy = _normalize_policy($policy_value);

    if ($policy eq '') {
        return {
            policy => DEFAULT_SUDOER_POLICY,
            source => 'default',
        };
    }

    if ($policy eq 'disabled') {
        return {
            policy => 'disabled',
            source => 'sudoerpolicy',
        };
    }

    if ($policy eq 'modern') {
        return {
            policy => 'modern',
            source => 'sudoerpolicy',
        };
    }

    if ($policy eq 'legacy') {
        return {
            policy => 'legacy',
            source => 'sudoerpolicy',
        };
    }

    return {
        policy => 'invalid',
        source => 'sudoerpolicy',
        error  => "unsupported sudoerpolicy value: $policy_value",
    };
}

sub sudoer_policy_warnings {
    my $site = shift || {};
    my @warnings;

    my $policy = _normalize_policy(_site_value($site, 'sudoerpolicy'));
    if ($policy ne '' && $policy ne 'legacy' && $policy ne 'modern' && $policy ne 'disabled') {
        push @warnings, "Unsupported site.sudoerpolicy '$policy'; sudoer postscript will fail.";
    }

    if ($policy eq '' || $policy eq 'legacy') {
        push @warnings, "site.sudoerpolicy is set to legacy mode which uses hardcoded credentials. " .
                       "Configure passwd table entry with key=sudoer and set site.sudoerpolicy=modern " .
                       "to use secure, administrator-defined credentials.";
    }

    return @warnings;
}

sub is_valid_sudoer_username {
    my $user = shift;
    return 0 unless defined $user && $user ne '';
    return 0 unless $user =~ /^[a-z_][a-z0-9_-]*$/;
    return 0 if $user =~ /^(root|bin|daemon|sys|adm|nobody|systemd-network|systemd-resolve|messagebus|sshd)$/;
    return 1;
}

1;
