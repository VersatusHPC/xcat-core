package XCAT::Test::File;

use strict;
use warnings;

use Cwd qw(abs_path);
use Exporter qw(import);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Slurper qw(read_binary write_binary);
use File::Spec;
use IO::Handle;

our @EXPORT_OK = qw(repo_path slurp_repo_file read_file read_optional_file write_file);

my $module_dir = dirname( File::Spec->rel2abs(__FILE__) );
my $repo_root = abs_path(
    File::Spec->catdir(
        $module_dir,
        File::Spec->updir(),
        File::Spec->updir(),
        File::Spec->updir(),
        File::Spec->updir(),
    )
);
die "Unable to resolve the repository root from $module_dir: $!" unless defined $repo_root;
my $module_path = File::Spec->catfile( $repo_root, 'xCAT-test', 'lib', 'XCAT', 'Test', 'File.pm' );
die "Unable to locate the repository test support at $module_path" unless -f $module_path;

sub repo_path {
    my ($relative) = @_;
    die "Repository-relative path is required" unless defined $relative && length $relative;
    die "Repository path must be relative: $relative" if File::Spec->file_name_is_absolute($relative);
    foreach my $part ( File::Spec->splitdir($relative) ) {
        die "Repository path must not escape the checkout: $relative" if $part eq File::Spec->updir();
    }

    return File::Spec->catfile( $repo_root, $relative );
}

sub slurp_repo_file {
    my ($relative) = @_;
    my $path = repo_path($relative);

    open( my $fh, '<:raw', $path ) or die "Unable to open $path for reading: $!";
    my $contents = do { local $/; <$fh> };
    unless ( defined $contents && !$fh->error ) {
        my $error = $!;
        close($fh);
        die "Unable to read $path: $error";
    }
    close($fh) or die "Unable to close $path: $!";

    return $contents;
}

#--------------------------------------------------------------------------

=head3 read_file

    Descriptions: Read a scratch file in raw mode.
    Arguments:    the path of the file
    Returns:      the complete contents; dies when the file cannot be read

=cut

#--------------------------------------------------------------------------
sub read_file {
    my ($path) = @_;
    my $bytes = read_binary($path);
    return defined($bytes) ? $bytes : q{};
}

#--------------------------------------------------------------------------

=head3 read_optional_file

    Descriptions: Read a scratch file that the code under test may not write.
    Arguments:    the path of the file
    Returns:      the complete contents, or an empty string when no file exists

=cut

#--------------------------------------------------------------------------
sub read_optional_file {
    my ($path) = @_;
    return q{} unless -e $path;
    return read_file($path);
}

#--------------------------------------------------------------------------

=head3 write_file

    Descriptions: Write a scratch file in raw mode, and create its parent
                  directories. A read-only file is replaced.
    Arguments:    the path of the file, the bytes, an optional mode
    Returns:      the path; dies on any error

=cut

#--------------------------------------------------------------------------
sub write_file {
    my ($path, $bytes, $mode) = @_;
    my $parent = dirname($path);
    make_path($parent) unless -d $parent;
    # A fixture can leave a file read-only, and a later write replaces it.
    chmod(0644, $path) if -f $path && !-w $path;
    write_binary($path, $bytes);
    if (defined $mode) {
        chmod($mode, $path) == 1 or die "Unable to set the mode of $path: $!";
    }
    return $path;
}

1;

__END__

=head1 NAME

XCAT::Test::File - repository file helpers for source-tree tests

=head1 FUNCTIONS

=head2 repo_path

Returns the absolute path for a repository-relative path.

=head2 slurp_repo_file

Reads a repository-relative file in raw mode and returns its complete contents.

=head2 read_file, read_optional_file, write_file

Raw reads and writes of scratch files. C<read_optional_file> returns an empty
string when the file does not exist. C<write_file> creates the parent
directories and sets the optional mode.

=cut
