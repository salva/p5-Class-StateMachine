package Class::StateMachine;

our $VERSION = '0.12';

package Class::StateMachine::Private;

use 5.010;
use strict;
use warnings;
use Carp;

use Hash::Util qw(fieldhash);

fieldhash my %state;
my ( %class_isa_stateful,
     %class_bootstrapped );

sub _init {
    my $self = shift;
    my $base_class = ref($self);
    my $class = _bootstrap_state_class($base_class, ($state{$self} //= 'new'));
    bless $self, $class;
}

sub _state {
    my ($self, $new_state) = @_;
    defined $state{$self} or _init($self);
    if (defined $new_state) {
        my $old_state = $state{$self};
        return $old_state if $new_state eq $old_state;
        my $leave = $self->can('leave_state');
        if ($leave) {
            $leave->($self, $old_state, $new_state);
            return $state{$self} if $state{$self} ne $old_state;
        }
        my $base_class = ref($self);
        $base_class =~ s|::__state__::.*$||;
        my $class = _bootstrap_state_class($base_class, $new_state);
        bless $self, $class;
        $state{$self} = $new_state;
        my $enter = $self->can('enter_state');
        if ($enter) {
            $enter->($self, $new_state, $old_state);
        }
    }
    $state{$self};
}

sub _bless {
    my ($self, $base_class) = @_;
    $base_class //= caller;
    my $class = _bootstrap_state_class($base_class, ($state{$self} //= 'new'));
    bless $self, $class;
}

sub _destroy {}

sub _bootstrap_class {
    my $class = shift;
    no strict 'refs';
    $class_isa_stateful{$class} = [ grep { Class::StateMachine->isa($_) }
				    @{*{$class.'::ISA'}{ARRAY}} ];
}

sub _bootstrap_state_class {
    my ($class, $state) = @_;
    my $state_class = "${class}::__state__::${state}";
    unless ($class_bootstrapped{$state_class}) {
	my $methods_class = _bootstrap_methods_class($class, $state);
	my $methods_class_any = _bootstrap_methods_class($class, '__any__');
	no strict 'refs';
	*{$state_class.'::ISA'} = [$methods_class, $methods_class_any, $class];
	$class_bootstrapped{$state_class} = 1;
    }
    return $state_class;
}

sub _bootstrap_methods_class {
    my ($class, $state, $no) = @_;
    my $methods_class = "${class}::__methods__::${state}";
    unless ($no or $class_bootstrapped{$methods_class}) {
	_bootstrap_class($class);
	no strict 'refs';
	my @isa =
	    map { _bootstrap_methods_class($_, $state) }
		@{$class_isa_stateful{$class}};
	*{$methods_class.'::ISA'} = \@isa;
    }
    return $methods_class;
}

my @state_methods;

use Devel::Peek 'CvGV';
sub _handle_attr_OnState {
    my ($class, $sub, $on_state) = @_;

    push @state_methods, [$class, $sub, $on_state];
}

CHECK {
    for (@state_methods) {
	my ($class, $sub, $on_state) = @$_;
	my $sym = CvGV($sub);
	my ($method) = $sym=~/::([^:]+)$/
	    or croak "invalid symbol name '$sym'";

	my @on_state = do {
	    no strict;
	    no warnings;
	    eval $on_state
	};
	Carp::croak("error inside OnState attribute declaration: $@") if $@;
	unless (@on_state) {
	    warnings::warnif('Class::StateMachine',
			     'no states on OnState attribute declaration');
	}
	no strict 'refs';
	for my $state (@on_state) {
	    $state = '__any__' unless defined $state;
	    my $state_class = _bootstrap_methods_class($class, $state, 1);
	    *{$state_class.'::'.$method} = $sub;
	}
	no warnings;
	*{$class.'::'.$method} =
	    sub {
		my $this = shift;
		my $state = $this->state;
		croak( defined($state)
		       ? "no particular method ${class}::${method} defined for state $state on obj $this"
		       : "method ${class}::${method} called before setting the state on obj $this" )
	    };
    }
}

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

*DESTROY = \&Class::StateMachine::Private::_destroy;

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

  sub new { Class::StateMachine::bless {}, shift }

  package main;

  my $sm = MySM->new;

  $sm->state('one');
  $sm->foo; # prints "on state one"

  $sm->state('two');
  $sm->foo; # prints "on state two"



=head1 DESCRIPTION

Class::StateMachine lets define, via the C<OnState> attribute, methods
that are dispatched depending on an internal C<state> property.

=head2 METHODS

These methods are available on objects of this class:

=over 4

=item $obj-E<gt>state

gets the object state

=item $obj-E<gt>state($new_state)

changes the object state

=item $obj-E<gt>rebless($class)

changes the object class in a compatible manner, target class should
also be derived from Class::StateMachine.

=back

=head1 BUGS

Because of certain limitations in current perl implementation of
attributed subroutines, attributes have to be processed on CHECK
blocks. That means that they will not be available before that, for
instance, on module initialization, or in BEGIN blocks.

=head1 SEE ALSO

L<attributes>, L<perlsub>, L<perlmod>, L<warnings>, L<Attribute::Handlers>.

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2003-2006 by Salvador FandiE<ntilde>o (sfandino@yahoo.com).

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.


=cut
