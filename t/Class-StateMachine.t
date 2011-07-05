#! /usr/bin/perl

use Test::More tests => 8;
BEGIN { use_ok('Class::StateMachine') };

package SM;

use warnings;
no warnings 'redefine';

use base 'Class::StateMachine';

sub foo : OnState(one) { 1 }

sub foo : OnState(two) { 2 }

sub foo : OnState(three) { 3 }

sub bar : OnState(__any__) { 'any' }

sub bar : OnState(five, six, seven) { 7 }


sub new {
    my $class=shift;
    bless {@_}, $class;
}

package main;

my $t = SM->new;
$t->state('one');
is($t->foo, 1, 'one');

$t->state('five');
is($t->bar, 7, 'multi five');

$t->state('two');
is($t->foo, 2, 'two');

$t->state('three');
is($t->foo, 3, 'three');

$t->state('sdfkjl');
is($t->bar, 'any', 'any');

ok (!eval { $t->foo; 1 }, 'die on no state-method defined');

$t->state('six');
is($t->bar, 7, 'multi six');


