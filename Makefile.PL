use 5.008;
use ExtUtils::MakeMaker;

WriteMakefile( NAME          => 'Class::StateMachine',
	       VERSION_FROM  => 'lib/Class/StateMachine.pm',
	       PREREQ_PM     => { Test::More => 0 },
	       ABSTRACT_FROM => 'lib/Class/StateMachine.pm',
	       AUTHOR        => 'Salvador Fandino <sfandino@yahoo.com>' );
