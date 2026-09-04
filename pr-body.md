# PR draft -- branch fix/genpassword-csprng (VersatusHPC/xcat-core)

Title: fix(xcat-core): genpassword and genUUID build credential material with a non-cryptographic RNG

Commits (test first, then fix, for each defect):

    e7fb0f33d test  genpassword draws secret material from a non-cryptographic RNG
    a63a891e1 fix   genpassword builds the TSIG and OMAPI secrets with a non-cryptographic RNG
    9c01ab485 test  genUUID mints the REST API bearer token with a non-cryptographic RNG
    037aced05 fix   genUUID mints the REST API bearer token with a non-cryptographic RNG
    54d8885ef test  genpassword has no bound on the number of reads it makes
    8fb24362a fix   genpassword has no bound on the number of reads it makes

## Body

xCAT builds credential material with Perl rand. genpassword builds the DDNS TSIG
secret, the ISC DHCP OMAPI secret, BMC passwords when site.genpasswords is set,
Active Directory machine account passwords, KVM graphics passwords and crypt
salts. genUUID with no arguments builds the REST API token id in xcatd.pm, and a
client that holds that token acts as the user it was issued to.

Perl rand is a drand48 generator, and srand truncates its seed to 32 bits.
A 32 character TSIG secret therefore holds at most 32 bits, not the 190 that its
length suggests, and a version 4 token id holds at most 32 bits, not 122.
xCAT::Utils::genpassword and xCAT::Utils::genUUID both did this, and ddns.pm,
dhcp.pm and bmcconfig.pm each carried a copy of genpassword.

Both routines now read /dev/urandom. genpassword discards the bytes that bias
the alphabet, and stops with an error after 10 reads per wanted character plus
100, so a device that returns only discarded bytes cannot keep it in the loop.
genUUID reads sixteen bytes and sets the RFC 4122 version and variant bits; its
version 1 path draws the clock sequence from the same device, and its version 5
path is unchanged. The three plugin copies of genpassword now call
xCAT::Utils::genpassword.

xCAT-test/unit/genpassword_csprng.t and xCAT-test/unit/genuuid_csprng.t drive
both routines through an injected random device, assert the exact output that
the bytes of that device produce, and count every call to rand and srand. Each
test commit precedes its fix commit and fails without it.

## Behaviour change

The genpassword alphabet is now 62 characters. The old string held '0' twice, so
int(rand 63) already produced '0' about twice as often as any other character.
Generated passwords keep the same length and the same [A-Za-z0-9] character
class, so no caller has to change.

## FIPS

Reading /dev/urandom does not block and needs no userspace generator and no new
Perl module.

The kernel does not serve /dev/urandom from the crypto API DRBG. On the FIPS
management node xcat52-mn (AlmaLinux 9.8, kernel 5.14.0-687.5.3.el9_8.x86_64,
/proc/sys/crypto/fips_enabled = 1) /proc/crypto lists the stdrng DRBG instances
with passing self tests, but /proc/kallsyms names urandom_read_iter and
crng_make_state, so the device comes from the kernel ChaCha20 generator in
drivers/char/random.c. A 32 byte read on that node returned in under a second.
The source comment on $RANDOM_DEVICE said the DRBG served the device; commit
037aced05 corrects it.

## Read limit, measured

Over 200000 runs of genpassword(8) against /dev/urandom the highest read count
was 6, against a limit of 180. For genpassword(32) it was 4, against 420.
