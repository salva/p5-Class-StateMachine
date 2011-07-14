package Class::StateMachine;

our $VERSION = '0.16';

our $debug //= 0;

package Class::StateMachine::Private;

use 5.010001;

sub _eval_states {
    # we want the state declarations evaluated inside a clean
    # environment (lexical free):
    eval $_[0]
}

use strict;
use warnings;
use Carp;

use mro;
use MRO::Define;
use Hash::Util qw(fieldhash);
use Devel::Peek 'CvGV';
use Package::Stash;
use Sub::Name;
use Scalar::Util qw(refaddr);

fieldhash my %state;
my ( %class_isa_stateful,
     %class_bootstrapped );

sub _debug {
    my $self = shift;
    my $class = Class::StateMachine::ref($self);
    my $state = $state{$self} // '<undef>';
    my $addr = refaddr($self);
    warn "${class}[$addr/$state]> @_\n";
}


sub _state {
    my($self, $new_state) = @_;
    $state{$self} // croak("object $self has no state, are you using Class::StateMachine::bless?");
    if (defined $new_state) {
        my $old_state = $state{$self};
        return $old_state if $new_state eq $old_state;
        $debug and _debug($self, "changing state from $old_state to $new_state");
        my $check = $self->can('check_state');
        if ($check) {
            $debug and _debug($self, "checking state $new_state");
            $check->($self, $new_state) or croak qq(invalid state "$new_state");
        }
        my $leave = $self->can('leave_state');
        if ($leave) {
            $debug and _debug($self, "calling leave_state($old_state, $new_state)");
            $leave->($self, $old_state, $new_state);
            if ($state{$self} ne $old_state) {
                $debug and _debug($self, "state transition from $old_state to $new_state shortcuted to $state{$self}");
                return $state{$self}
            }
        }
        my $base_class = ref($self);
        $base_class =~ s|::__state__::.*$||;
        my $class = _bootstrap_state_class($base_class, $new_state);
        bless $self, $class;
        $debug and _debug($self, "real class set to $class");
        $state{$self} = $new_state;
        my $enter = $self->can('enter_state');
        if ($enter) {
            $debug and _debug($self, "calling enter_state($new_state, $old_state)");
            $enter->($self, $new_state, $old_state);
        }
    }
    $state{$self};
}

sub _bless {
    my ($self, $base_class, $state) = @_;
    $base_class //= caller;
    if (defined $state) {
        defined $state{$self} and croak "unable to change state when reblessing";
        $state{$self} = $state;
    }
    else {
        $state{$self} //= 'new';
    }
    my $class = _bootstrap_state_class($base_class, $state{$self});
    bless $self, $class;
    $debug and _debug($self, "real class set to $class");
    $self;
}

sub _bootstrap_state_class {
    my ($class, $state) = @_;
    my $state_class = "${class}::__state__::${state}";
    unless ($class_bootstrapped{$state_class}) {
        # disallow control characters and colons inside state names:
        $state =~ m|^[\x21-\x39\x3b-\x7f]+$| or croak "'$state' is not a valid state name";
	$class_bootstrapped{$state_class} = 1;

	no strict 'refs';
        @{$state_class.'::ISA'} = $class;
        # @{$state_class.'::ISA'} = (@on_state, $class);
        ${$state_class.'::state'} = $state;
        ${$state_class.'::base_class'} = $class;
        ${$state_class.'::state_class'} = $state_class;
        mro::set_mro($state_class, 'statemachine');
    }
    return $state_class;
}

my @state_methods;

sub _handle_attr_OnState {
    my ($class, $sub, $on_state) = @_;
    my ($filename, $line) = (caller 2)[1,2];
    my ($err, @on_state);
    do {
        local $@;
        @on_state = _eval_states <<EOE;
package $class;
no warnings 'reserved';
# line $line $filename
$on_state;
EOE
        $err = $@;
    };
    croak $err if $err;
    grep(!defined, @on_state) and croak "undef is not a valid state";
    @on_state or warnings::warnif('Class::StateMachine',
                                  'no states on OnState attribute declaration');
    push @state_methods, [$class, $sub, @on_state];
}

sub _move_state_methods {
    while (@state_methods) {
	my ($class, $sub, @on_state) = @{shift @state_methods};
	my $sym = CvGV($sub);
	my ($method) = $sym=~/::([^:]+)$/ or croak "invalid symbol name '$sym'";

        my $stash = Package::Stash->new($class);
        $stash->remove_symbol("&$method");

	for my $state (@on_state) {
            my $methods_class = join('::', $class, '__methods__', $state);
	    my $full_name = "${methods_class}::$method";
            # print "registering method at $full_name\n";
            no strict 'refs';
	    *$full_name = subname($full_name, $sub);
	}
    }
}

# use Data::Dumper;
sub _statemachine_mro {
    my $stash = shift;
    # print Dumper $stash;
    _move_state_methods if @state_methods;
    my $state_class = ${$stash->{state_class}};
    my $base_class = ${$stash->{base_class}};
    my $state = ${$stash->{state}};
    my @linear = @{mro::get_linear_isa($base_class)};
    my @derived = grep { $_->isa('Class::StateMachine') } @linear;
    my @state = ($state_class,
                 ( grep mro::get_pkg_gen($_),
                   map(join('::', $_, '__methods__', $state   ), @derived),
                   map(join('::', $_, '__methods__', '__any__'), @derived) ),
                 @linear);
    # print "mro $base_class/$state [@linear] => [@state]\n";
    \@state;
}

MRO::Define::register_mro('statemachine' => \&_statemachine_mro);

package Class::StateMachine;
use warnings::register;

sub MODIFY_CODE_ATTRIBUTES {
    my ($class, undef, @attr) = @_;
    grep { !/^OnState\((.*)\)$/
	       or (Class::StateMachine::Private::_handle_attr_OnState($class, $_[1], $1), 0) } @attr;
}

*state = \&Class::StateMachine::Private::_state;
*rebless = \&Class::StateMachine::Private::_bless;
*bless = \&Class::StateMachine::Private::_bless;

sub ref {
    my $class = ref $_[0];
    return '' if $class eq '';
    no strict 'refs';
    ${$class .'::base_class'} // $class;
}

sub DESTROY {}
sub import {}

sub AUTOLOAD {
    our $AUTOLOAD;
    my $self = $_[0];
    if (CORE::ref $self and defined $state{$self}) {
        my $state = $state{$self};
        my $method = $AUTOLOAD;
        $method =~ s/.*:://;
        my $state_class = CORE::ref($self);
        my @state_mro = @{mro::get_linear_isa($state_class)};
        my $base_class = Class::StateMachine::ref($self);
        my @base_mro = @{mro::get_linear_isa($base_class)};

        my @submethods;
        for my $class (@base_mro) {
            no strict 'refs';
            if (exists ${"${class}::"}{"__methods__::"}) {
                my $methods = "${class}::__methods__::";
                for my $state (grep /::$/, keys %$methods) {
                    exists ${"$methods$state"}{$method} and
                        push @submethods, "$methods$state$method";
                }
            }
            defined *{"${class}::$method"}{CODE} and
                push @submethods, "${class}::$method";
        }

        my $error = join("\n",
                         qq|Can't locate Class::StateMachine object method "$method" via package "$base_class" ("$state_class") for object in state "$state"|,
                         "The base mro is:",
                         "    " . join("\n    ", @base_mro),
                         "The state mro is:",
                         "    " . join("\n    ", @state_mro),
                         "The submethods on the inheritance chain are:",
                         "    " . join("\n    ", @submethods),
                         "...");
        Carp::croak $error;
    }
    else {
        Carp::croak "Undefined subroutine &$AUTOLOAD called"
    }
}

sub install_method {
    my ($class, $sub, @states) = @_;
    CORE::ref $class and Carp::croak "$class is not a package valid package name";
    CODE::ref $sub eq 'CODE' or Carp::croak "$sub is not a subroutine reference";
    push @state_methods, [$class, $sub, @states];
    Class::StateMachine::Private::_move_state_methods;
}

1;
__END__

=head1 NAME

Class::StateMachine - define classes for state machines

=head1 SYNOPSIS

  package MySM;
  no warnings 'redefine';

  use parent 'Class::StateMachine';

  sub foo : OnState(one) { print "on state one\n" }
  sub foo : OnState(two) { print "on state two\n" }

  sub bar : OnState(__any__) { print "default action\n" }
  sub bar : OnState(three, five, seven) { print "on several states\n" }
  sub bar : OnState(one) { print "on state one\n" }

  sub new {
      my $class = shift;
      my $self = {};
      Class::StateMachine::bless $self, $class;
      $self;
  }

  sub leave_state : OnState(one) { print "leaving state $_[1] from $_[2]" }
  sub enter_state : OnState(two) { print "entering state $_[1] from $_[2]" }

  package main;

  my $sm = MySM->new;

  $sm->state('one');
  $sm->foo; # prints "on state one"

  $sm->state('two');
  $sm->foo; # prints "on state two"


=head1 DESCRIPTION

This module allows to build classes whose instance behavior (methods)
depends not only on inheritance but also on some internal instance
state.

For instance, suppose we want to develop a Dog class implementing the
following behavior:

  my $dog = Dog->new;
  $dog->state("happy");
  $dog->on_touched_head; # the dog will move his tail
  $dog->state("angry");
  $dog->on_touched_head; # the dog will bite you

With the help of Class::StateMachine, that state dependant behaviour
can be easily programmed using the C<OnState> subroutine attribute as
follows:

  package Dog;

  use parent 'Class::StateMachine';

  sub on_touched_head : OnState(happy) { shift->move_tail }
  sub on_touched_head : OnState(angry) { shift->bite }

=head2 Object construction

Class::StateMachine does not imposse any particular type of data
structure for the instance objects. Any Perl reference type (HASH,
ARRAY, SCALAR, GLOB, etc.) can be used.

The unique condition is that must be fulfilled is to use the C<bless>
subrutine provided by Class::StateMachine instead of the Perl builtin
of the same name.

For instance:

  package Dog;

  sub new {
    my $class = shift;
    my $dog = { name => 'Oscar' };
    Class::StateMachine::bless($dog, $class, 'happy');
  }

A default state C<new> gets assigned to the object if the third
parameter to C<Class::StateMachine::bless> is ommited.

=head2 Instance state

The instance state is maintained internally by Class::StateMachine and can be
accessed though the L</state> method:

  my $state = Dog->state;

State changes must be performed explicitly calling the C<state> method
with the new state as an argument:

  Dog->state('tired');

Class::StateMachine will not change the state of your objects in any
other way.

If you want to limit the possible set of states that the objects of
some class can take, define a L</state_check> method for that class:

  package Dog;
  ...
  sub state_check {
    my ($self, $state) = @_;
    $state =~ /^(?:happy|angry|tired)$/
  }

That will make die any call to C<state> requesting a change to an
invalid state.

New objects get assigned the state 'new' when they are created.

=head2 Method definition

Inside a class derived from Class::StateMachine, methods (submethods)
can be assigned to some particular states using the C<OnState>
attribute with a list of the states where it applies.

  sub bark :OnState(happy, tired) { play "happy_bark.wav" }
  sub bark :OnState(injured) { play "pitiful_bark.wav" }

The text inside the OnState parents is evaluated in list context on
the current package and with strictures turned off in order to allow
usage of barewords.

For instance:

  sub foo : OnState(map "foo$_", a..z) { ... }

Though note that lexicals variables will not be reachable from the
text inside the parents. Note also that Perl does not allow attribute
declarations to spawn over several lines.

A special state C<__any__> can be used to indicate a default submethod
that is called in case a specific submethod has not been declared for
the current object state.

For instance:

  sub happy :OnState(happy  ) { say "I am happy" }
  sub happy :OnState(__any__) { say "I am not happy" }

=head2 Method resolution order

What happens when you declare submethods spreaded among a class
inheritance hierarchy?

Class::StateMachine will search for the method as follows:

=over 4

=item 1

Search in the inheritance tree for a specific submethod declared for
the current object state.

=item 2

Search in the inheritance tree for a submethod declared for the pseudo
state C<__any__>.

=item 3

Search for a regular method defined without the C<OnState> attribute.

=item 4

Use the AUTOLOAD mechanism.

=back

L<mro> can be used to set the search order inside the inheritance
trees (for instance, the default deep-first or C3).

=head2 State transitions

When an object changes between two different states, the methods
L</leave_state> and L</enter_state> are called if they are defined.

Note that they can be defined using the C<OnState> attribute:

  package Dog;
  ...
  sub enter_state :OnState(angry) { shift->bark }
  sub enter_state :OnState(tired) { shift->lie_down }


=head2 API

These are the methods available from Class::StateMachine:

=over 4

=item Class::StateMachine::bless($obj, $class, $state)

=item $obj-E<gt>bless($class)

Sets or changes the object class in a manner compatible with
Class::StateMachine.

This function must be used as the way to create new objetcs of classes
derived from Class::StateMachine.

If the third argument C<$state> is not given, C<new> is used as the
default.

=item $obj-E<gt>state

X<state>Gets the object state.

=item $obj-E<gt>state($new_state)

Changes the object state.

This method calls back the methods C<check_state>, C<leave_state> and
C<enter_state> if they are defined in the class or any of its
subclasses for the corresponding state.

If C<$new_state> equals the current object state, this method does
nothing (including not invoking the callback methods).

=over 4

=item $self->check_state($new_state)

X<check_state>This callback can be used to limit the set of states
acceptable for the object. If the method returns a false value the
C<state> call will die.

If this method is not defined any state will be valid.

=item $self->leave_state($old_state, $new_state)

X<leave_state>This method is called just before changing the state.

It the state is changed from its inside to something different than
$old_state, the requested state change is canceled.

=item $self->enter_state($new_state, $old_state)

X<enter_state>This method is called just after changing the state to
the new value.

=back

=item Class::StateMachine::ref($obj)

=item $obj-E<gt>ref

Returns the class of the object without the parts related to
Class::StateMachine magic.

=item Class::StateMachine::install_method($class, $sub, @states)

Sets a submethod for a given class/state combination.

=back

=head2 Debugging

Class::StateMachine supports a debugging mode that prints traces of
state changes and callback invocation. It can be enabled as follows:

  $Class::StateMachine::debug = 1;


=head2 Internals

This module internally plays with the inheritance chain creating new
classes and reblessing objects on the fly and (ab)using the L<mro>
mechanism in funny ways.

The objects state is maintained inside a L<Hash::Util::FieldHash>.

=head1 BUGS

Backward compatibility has been broken in version 0.13 in order to
actualize the class to use modern Perl features as mro and provide
sanner semantics.

Passing several states in the same submethod definition can break the
next::method machinery from the mro package.

For instace:

  sub foo :OnState(one, two, three) { shift->next::method(@_) }

may not work as expected.

=head1 SEE ALSO

L<attributes>, L<perlsub>, L<perlmod>, L<Attribute::Handlers>, L<mro>,
L<MRO::Define>.

The C<dog.pl> example included within the package.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2003-2006, 2011 by Salvador FandiE<ntilde>o (sfandino@yahoo.com).

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.


=cut
