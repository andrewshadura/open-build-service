use strict;
use warnings;

use Test::More;
use FindBin;

use lib "$FindBin::Bin/lib/";
use Test::Mock::BSConfig;

use Capture::Tiny ':all';

plan tests => 7;

require_ok('BSUtil');

### Basic tests of the functionality

my $out = capture_merged {
  my $guard = BSUtil::prefix_stdout("P: ");
  print "alpha\n";
  print "beta\n";
  $guard->finish();
};
is($out, "P: alpha\nP: beta\n", 'each line written under the guard is prefixed');

$out = capture_merged {
  my $guard = BSUtil::prefix_stdout("Q: ");
  print "one\ntwo\nthree\n";
  $guard->finish();
};
is($out, "Q: one\nQ: two\nQ: three\n", 'multiple lines in one write are each prefixed');

$out = capture_merged {
  my $guard = BSUtil::prefix_stdout("R: ");
  print "no newline";
  $guard->finish();
};
is($out, "R: no newline\n", 'trailing line without newline is emitted with one');

### Prefixing doesn't happen outside of the prefixed context

$out = capture_merged {
  {
    my $guard = BSUtil::prefix_stdout("S: ");
    print "inside\n";
  }   # guard destroyed here
  print "outside\n";
};
is($out, "S: inside\noutside\n", 'STDOUT is restored after the guard is destroyed');

### Die means die and prefix is gone

$out = capture_merged {
  eval {
    my $guard = BSUtil::prefix_stdout("V: ");
    print "before die\n";
    die "boom\n";
  };
  print "after eval\n";   # STDOUT must already be restored here
};
is($out, "V: before die\nafter eval\n", 'guard tears down and restores STDOUT on die');

### Capture::Tiny coexists with prefixing
# A capture taken *while* a prefix_stdout guard is active used to die with
# "Couldn't seek on capture handle for stdout" when prefixing was done with a
# PerlIO layer.  With the guard it must work, and the nested capture's output
# must not leak into the outer (prefixed) stream.

$out = capture_merged {
  my $guard = BSUtil::prefix_stdout("W: ");
  print "outer before\n";
  my $inner = capture_merged {
    print "inner captured\n";
  };
  print "inner was: $inner";   # $inner already ends in "\n"
  print "outer after\n";
  $guard->finish();
};
is($out,
   "W: outer before\nW: inner was: inner captured\nW: outer after\n",
   'a nested capture works under the guard and does not leak into prefixed output');
