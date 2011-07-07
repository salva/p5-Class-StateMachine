package Class::StateMachine;

our $VERSION = '0.13';

package Class::StateMachine::Private;

use 5.010001;

sub _eval_states {
    # we want the state declarations evaluated inside a clean
    # environment (lexical free):
    print STDERR "evaluating $_[0]\n";
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
    my($self, $new_state) = @_;
    defined $state{$self} or _init($self);
    if (defined $new_state) {
        my $old_state = $state{$self};
        return $old_state if $new_state eq $old_state;
        my $check = $self->can('check_state');
        if ($check) {
            $check->($self, $new_state) or croak qq(invalid state "$state");
        }
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

sub _bootstrap_state_class {
    my ($class, $state) = @_;
    my $state_class = "${class}::__state__::${state}";
    unless ($class_bootstrapped{$state_class}) {
        # disallow control characters and colons inside state names:
        $state =~ m|^[\x21-\x39\x3b-\x7f]+$| or croak "'$state' is not a valid state name";
	$class_bootstrapped{$state_class} = 1;

        # my @linear = @{mro::get_linear_isa($class)};
        # my @derived = grep { $_->isa('Class::StateMachine') } @linear;
        # my @on_state = grep mro::get_pkg_gen($_), ( map(join('::', $_, '__methods__', $state   ), @derived),
        # print "mro $class/$state [@linear] => [@on_state]\n";

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
    my ($err, @on_state);
    do {
        local $@;
        @on_state = _eval_states "package $class; $on_state";
        $err = $@;
    };
    croak $err if $err;
    @on_state or warnings::warnif('Class::StateMachine',
                                  'no states on OnState attribute declaration');
    push @state_methods, [$class, $sub, @on_state];
}

sub _move_state_methods {
    for (@state_methods) {
	my ($class, $sub, @on_state) = @$_;
	my $sym = CvGV($sub);
	my ($method) = $sym=~/::([^:]+)$/ or croak "invalid symbol name '$sym'";

        my $stash = Package::Stash->new($class);
        $stash->remove_symbol("&$method");

        print "\@on_state: @on_state\n";

        #my (@on_state, $err);
        #do {
        #    local $@;
	#    @on_state = _eval_states "package $class; $on_state";
        #    $err = $@;
	#};
	# croak("error inside OnState attribute declaration: $err") if $err;

	for my $state (@on_state) {
            my $methods_class = join('::', $class, '__methods__', ($state // '__any__'));
	    my $full_name = "${methods_class}::$method";
            # print "registering method at $full_name\n";
            no strict 'refs';
	    *$full_name = subname($full_name, $sub);
	}
    }
    @state_methods = ();
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

#CHECK {
#    warn "CHECKing";
#    _move_state_methods;
#}

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
