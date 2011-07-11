use 5.010001;

use ExtUtils::MakeMaker;

WriteMakefile( NAME          => 'Class::StateMachine',
	       VERSION_FROM  => 'lib/Class/StateMachine.pm',
	       PREREQ_PM     => { 'Test::More' => 0,
                                  'MRO::Define' => '0.01',
                                  'Package::Stash' => 0 },
	       ABSTRACT_FROM => 'lib/Class/StateMachine.pm',
	       AUTHOR        => 'Salvador Fandino <sfandino@yahoo.com>' );
