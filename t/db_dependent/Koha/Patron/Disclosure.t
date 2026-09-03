#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use FindBin;
use JSON;
use Test::Exception;
use Test::MockModule;
use Test::More;
use Test::NoWarnings qw( had_no_warnings );
use YAML::XS;

use t::lib::Mocks;
use t::lib::TestBuilder;

use Koha::ActionLog;
use Koha::ActionLogs;
use Koha::Database;
use Koha::Patron::Disclosure;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

{

    package Test::PatronDisclosure::Logger;

    sub new {
        return bless { messages => [] }, shift;
    }

    sub debug {
        my ( $self, $message ) = @_;
        push @{ $self->{messages} }, ref($message) eq 'CODE' ? $message->() : $message;
        return;
    }

    sub messages {
        my ($self) = @_;
        return $self->{messages};
    }
}

my $logger      = Test::PatronDisclosure::Logger->new;
my $logger_mock = Test::MockModule->new('Koha::Logger');
$logger_mock->redefine( get => sub { return $logger } );

sub new_event {
    my (%overrides) = @_;

    return Koha::Patron::Disclosure->new(
        {
            actor_id    => $overrides{actor_id},
            surface     => $overrides{surface}     // 'patrons.search.results',
            breadth     => $overrides{breadth}     // 'list_page',
            auth_source => $overrides{auth_source} // 'session',
            interface   => $overrides{interface}   // 'api',
        }
    );
}

sub disclosure_logs {
    return Koha::ActionLogs->search(
        {
            module => Koha::Patron::Disclosure::MODULE,
            action => Koha::Patron::Disclosure::ACTION,
        },
        { order_by => 'action_id' }
    );
}

subtest 'Patron REST schema classification is exhaustive' => sub {
    plan tests => 3;

    my $schema_definition = YAML::XS::LoadFile("$FindBin::Bin/../../../../api/v1/swagger/definitions/patron.yaml");
    my $field_classes     = Koha::Patron::Disclosure->api_field_classes;

    is_deeply(
        [ sort keys %{$field_classes} ],
        [ sort keys %{ $schema_definition->{properties} } ],
        'every schema property has exactly one classification decision'
    );
    ok(
        !grep( { ref( $field_classes->{$_} ) ne 'ARRAY' || !@{ $field_classes->{$_} } } keys %{$field_classes} ),
        'every schema property maps to at least one data class'
    );

    my %valid_classes = map { $_ => 1 } @{ Koha::Patron::Disclosure->valid_data_classes };
    is_deeply(
        [
            sort map {
                my $field = $_;
                map { "$field:$_" } grep { !$valid_classes{$_} } @{ $field_classes->{$field} }
            } keys %{$field_classes}
        ],
        [],
        'schema properties use only the closed data-class vocabulary'
    );
};

subtest 'preference gates event creation, not an event already in flight' => sub {
    plan tests => 7;

    $schema->storage->txn_begin;
    @{ $logger->messages } = ();
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog',         0 );
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureMaxSubjects', 1000 );

    my $actor  = $builder->build_object( { class => 'Koha::Patrons' } );
    my $patron = $builder->build_object( { class => 'Koha::Patrons' } );

    is(
        Koha::Patron::Disclosure->new_if_enabled(
            {
                actor_id    => $actor->id,
                surface     => 'patrons.record.api',
                breadth     => 'record',
                auth_source => 'basic',
                interface   => 'api',
            }
        ),
        undef,
        'new_if_enabled returns undef'
    );

    is( disclosure_logs()->count,      0, 'no action logs are written' );
    is( scalar @{ $logger->messages }, 0, 'no logger message is emitted' );

    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog', 1 );
    my $event = Koha::Patron::Disclosure->new_if_enabled(
        {
            actor_id    => $actor->id,
            surface     => 'patrons.record.api',
            breadth     => 'record',
            auth_source => 'basic',
            interface   => 'api',
        }
    );
    ok( $event, 'an enabled request creates an event' );
    $event->add_subject( { patron_id => $patron->id, data_classes => ['identity'] } );

    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog', 0 );
    like( $event->commit, qr/\A[0-9a-f-]{36}\z/, 'an in-flight event commits after the preference changes' );
    is( disclosure_logs()->count,      1, 'the in-flight disclosure row is not lost' );
    is( scalar @{ $logger->messages }, 1, 'the committed event emits one logger message' );

    $schema->storage->txn_rollback;
};

subtest 'closed event and subject vocabularies' => sub {
    plan tests => 19;

    $schema->storage->txn_begin;
    @{ $logger->messages } = ();
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog',         1 );
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureMaxSubjects', 1000 );

    my $actor = $builder->build_object( { class => 'Koha::Patrons' } );

    throws_ok { new_event( actor_id => 0 ) } qr/actor_id must be a positive integer/, 'actor zero is rejected';
    throws_ok { new_event( actor_id => $actor->id, surface => 'raw.cgi.path' ) }
    qr/Unknown patron disclosure surface/, 'unknown surfaces are rejected';
    throws_ok { new_event( actor_id => $actor->id, breadth => 'all' ) }
    qr/Unknown patron disclosure breadth/, 'unknown breadth is rejected';
    throws_ok {
        new_event(
            actor_id => $actor->id,
            surface  => 'patrons.record.api',
            breadth  => 'list_page'
        );
    }
    qr/requires breadth 'record'/, 'surface and breadth must agree';
    throws_ok { new_event( actor_id => $actor->id, auth_source => 'header' ) }
    qr/Unknown patron disclosure authentication source/, 'unknown authentication sources are rejected';
    throws_ok { new_event( actor_id => $actor->id, interface => 'opac' ) }
    qr/Unknown patron disclosure interface/, 'non-staff interfaces are rejected';
    throws_ok {
        Koha::Patron::Disclosure->new(
            {
                actor_id    => $actor->id,
                surface     => 'patrons.record.api',
                breadth     => 'record',
                auth_source => 'session',
                interface   => 'api',
                search_term => 'private sentinel',
            }
        );
    }
    qr/unknown key.*search_term/i, 'source PII cannot be added to event parameters';

    my $event = new_event( actor_id => $actor->id );
    throws_ok { $event->add_subject( { patron_id => 0, data_classes => ['identity'] } ) }
    qr/patron_id must be a positive integer/, 'patron zero is rejected';
    throws_ok { $event->add_subject( { patron_id => 1, data_classes => [] } ) }
    qr/data_classes must be a non-empty array reference/, 'empty class sets are rejected';
    throws_ok { $event->add_subject( { patron_id => 1, data_classes => ['medical'] } ) }
    qr/Unknown patron disclosure data class/, 'unknown data classes are rejected';
    throws_ok { $event->add_api_subject( { patron_id => 1, fields => ['future_secret'] } ) }
    qr/Unclassified Patron REST field/, 'unclassified API fields are rejected';
    throws_ok {
        $event->add_subject(
            {
                patron_id    => 1,
                data_classes => ['identity'],
                surname      => 'private sentinel',
            }
        );
    }
    qr/unknown key.*surname/i, 'source PII cannot be added to subject parameters';

    is( Koha::Patron::Disclosure->surface_breadth('patrons.record.details'), 'record', 'surface is registered' );
    is(
        Koha::Patron::Disclosure->surface_breadth('patrons.record.duplicate_match'),
        'record',
        'duplicate-match surface is registered'
    );
    is(
        Koha::Patron::Disclosure->surface_breadth('patrons.checkouts.current_batch'),
        'workflow_batch',
        'multi-patron checkout disclosure has workflow-batch breadth'
    );
    is( Koha::Patron::Disclosure->surface_breadth('unknown'), undef, 'unknown surface has no breadth' );
    ok(
        grep( { $_ eq 'extended_attributes' } @{ Koha::Patron::Disclosure->valid_data_classes } ),
        'extended attributes have a closed coarse class'
    );
    is( disclosure_logs()->count,      0, 'validation failures write no rows' );
    is( scalar @{ $logger->messages }, 0, 'validation failures emit no logger messages' );

    $schema->storage->txn_rollback;
};

subtest 'supported non-Patron API references add exact patron subjects' => sub {
    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog',         1 );
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureMaxSubjects', 1000 );

    my $actor           = $builder->build_object( { class => 'Koha::Patrons' } );
    my $patron          = $builder->build_object( { class => 'Koha::Patrons' } );
    my $claim_patron    = $builder->build_object( { class => 'Koha::Patrons' } );
    my $booking_patron  = $builder->build_object( { class => 'Koha::Patrons' } );
    my $historic_patron = $builder->build_object( { class => 'Koha::Patrons' } );
    my $ignored         = $builder->build_object( { class => 'Koha::Patrons' } );
    my $event           = new_event(
        actor_id => $actor->id,
        surface  => 'catalogue.items.patron_status',
    );

    $event->add_api_reference_subjects(
        {
            object         => bless( {}, 'Koha::Checkout' ),
            representation => { patron_id => $patron->id, issuer_id => $actor->id },
        }
    );
    $event->add_api_reference_subjects(
        {
            object         => bless( {}, 'Koha::Checkouts::ReturnClaim' ),
            representation => { patron_id => $claim_patron->id, created_by => $actor->id },
        }
    );
    $event->add_api_reference_subjects(
        {
            object         => bless( {}, 'Koha::Checkout' ),
            representation => { issuer_id => $actor->id },
        }
    );
    $event->add_api_reference_subjects(
        {
            object         => bless( {}, 'Koha::Booking' ),
            representation => { patron_id => $booking_patron->id },
        }
    );
    $event->add_api_reference_subjects(
        {
            object         => bless( {}, 'Koha::Old::Checkout' ),
            representation => { patron_id => $historic_patron->id },
        }
    );
    $event->add_api_reference_subjects(
        {
            object         => bless( {}, 'Koha::UnclassifiedResource' ),
            representation => { patron_id => $ignored->id },
        }
    );

    is( $event->subject_count, 4, 'only supported patron-owner references become subjects' );
    $event->commit;

    my @logs = disclosure_logs()->search( { user => $actor->id } )->as_list;
    is_deeply(
        [ map { 0 + $_->object } @logs ],
        [ sort { $a <=> $b } ( $patron->id, $claim_patron->id, $booking_patron->id, $historic_patron->id ) ],
        'patron IDs are exact and staff provenance IDs are excluded'
    );
    my %classes = map { $_->object => JSON->new->decode( $_->info )->{data_classes} } @logs;
    is_deeply(
        $classes{ $patron->id },
        [qw( circulation_current identity )],
        'checkout ownership represents current circulation data'
    );
    is_deeply(
        $classes{ $claim_patron->id },
        [qw( identity service_activity )],
        'return-claim ownership represents patron-attributable service activity'
    );
    is_deeply(
        $classes{ $booking_patron->id },
        [qw( identity service_activity )],
        'booking ownership represents patron-attributable service activity'
    );
    is_deeply(
        $classes{ $historic_patron->id },
        [qw( circulation_history identity )],
        'old-checkout ownership represents circulation history'
    );

    $schema->storage->txn_rollback;
    done_testing;
};

subtest 'relationship-debt aggregates retain exact patron provenance' => sub {
    plan tests => 9;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'borrowerRelationship',                   'parent' );
    t::lib::Mocks::mock_preference( 'NoIssuesChargeGuarantees',               1 );
    t::lib::Mocks::mock_preference( 'NoIssuesChargeGuarantorsWithGuarantees', 1 );

    my $parent_1 = $builder->build_object( { class => 'Koha::Patrons' } );
    my $parent_2 = $builder->build_object( { class => 'Koha::Patrons' } );
    my $child_1  = $builder->build_object( { class => 'Koha::Patrons' } );
    my $child_2  = $builder->build_object( { class => 'Koha::Patrons' } );

    $child_1->add_guarantor( { guarantor_id => $parent_1->id, relationship => 'parent' } );
    $child_1->add_guarantor( { guarantor_id => $parent_2->id, relationship => 'parent' } );
    $child_2->add_guarantor( { guarantor_id => $parent_1->id, relationship => 'parent' } );
    $child_2->add_guarantor( { guarantor_id => $parent_2->id, relationship => 'parent' } );

    my %amounts = (
        $parent_1->id => 3,
        $parent_2->id => 5,
        $child_1->id  => 7,
        $child_2->id  => 2,
    );
    for my $patron_id ( keys %amounts ) {
        $builder->build_object(
            {
                class => 'Koha::Account::Lines',
                value => {
                    borrowernumber    => $patron_id,
                    amount            => $amounts{$patron_id},
                    amountoutstanding => $amounts{$patron_id},
                    debit_type_code   => 'OVERDUE',
                },
            }
        );
    }

    my $details = $child_1->relationships_debt_details(
        { include_guarantors => 1, only_this_guarantor => 0, include_this_patron => 1 } );
    is( $details->{amount}, 17, 'the aggregate amount is unchanged' );
    is_deeply(
        $details->{patron_ids},
        [ sort { $a <=> $b } keys %amounts ],
        'every patron whose balance contributed to the aggregate is retained'
    );
    is(
        $child_1->relationships_debt( { include_guarantors => 1, only_this_guarantor => 0, include_this_patron => 1 } ),
        17,
        'the existing scalar method delegates to the detailed calculation'
    );

    $child_1->category->noissueschargeguarantorswithguarantees(undef)->store;
    my $limits = $child_1->is_patron_inside_charge_limits( { include_patron_ids => 1 } );
    is(
        $limits->{NoIssuesChargeGuarantorsWithGuarantees}->{charge}, 17,
        'charge-limit calculation uses the detail amount'
    );
    is_deeply(
        $limits->{NoIssuesChargeGuarantorsWithGuarantees}->{patron_ids},
        [ sort { $a <=> $b } keys %amounts ],
        'charge-limit result exposes exact aggregate provenance to the response audit'
    );

    $parent_1->category->noissueschargeguarantees(undef)->store;
    my $guarantee_limits = $parent_1->is_patron_inside_charge_limits( { include_patron_ids => 1 } );
    is(
        $guarantee_limits->{NoIssuesChargeGuarantees}->{charge},
        $amounts{ $child_1->id } + $amounts{ $child_2->id },
        'direct-guarantee charge total is unchanged'
    );
    is_deeply(
        $guarantee_limits->{NoIssuesChargeGuarantees}->{patron_ids},
        [ sort { $a <=> $b } ( $child_1->id, $child_2->id ) ],
        'direct-guarantee calculation retains its exact patron IDs'
    );

    my $default_limits = $parent_1->is_patron_inside_charge_limits;
    ok(
        !exists $default_limits->{NoIssuesChargeGuarantees}->{patron_ids},
        'the default direct-guarantee result does not expose audit provenance'
    );
    ok(
        !exists $default_limits->{NoIssuesChargeGuarantorsWithGuarantees}->{patron_ids},
        'the default guarantor result keeps its existing public shape'
    );

    $schema->storage->txn_rollback;
};

subtest 'Patron serialization uses the positive accessibility decision' => sub {
    plan tests => 6;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog',         1 );
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureMaxSubjects', 1000 );
    @{ $logger->messages } = ();

    my $actor  = $builder->build_object( { class => 'Koha::Patrons' } );
    my $patron = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => {
                branchcode => $actor->branchcode,
                surname    => 'REDACTED_PRIVATE_SENTINEL',
            },
        }
    );
    my $event = new_event(
        actor_id => $actor->id,
        surface  => 'patrons.record.api',
        breadth  => 'record',
    );

    my $patron_mock = Test::MockModule->new('Koha::Patron');
    $patron_mock->redefine( is_accessible => sub { return 0 } );

    throws_ok {
        $patron->to_api(
            {
                user                      => $actor,
                _patron_disclosure_active => 1,
            }
        );
    }
    qr/requires the serialized_patrons disclosure strategy/,
        'an active covered operation cannot serialize a Patron through an undeclared strategy';

    my $representation = $patron->to_api(
        {
            user              => $actor,
            patron_disclosure => $event,
        }
    );

    ok(
        exists $representation->{surname} && !defined $representation->{surname},
        'the inaccessible Patron representation retains a null redacted field'
    );
    is( $representation->{library_id}, $patron->branchcode, 'the mapped unredacted field remains visible' );

    $event->commit;
    my $log = disclosure_logs()->single;
    is( $log->object, $patron->id, 'the internal subject ID is exact even though the response ID is redacted' );
    is_deeply(
        JSON->new->decode( $log->info )->{data_classes},
        [qw( circulation_current notes_restrictions profile )],
        'classes come from positively visible mapped and calculated fields, not null-key presence'
    );
    is( disclosure_logs()->count, 1, 'serialization writes one subject row' );

    $schema->storage->txn_rollback;
};

subtest 'exact transactional rows, class union, and event identity' => sub {
    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog',         1 );
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureMaxSubjects', 1000 );
    @{ $logger->messages } = ();

    my $actor   = $builder->build_object( { class => 'Koha::Patrons' } );
    my $patron1 = $builder->build_object( { class => 'Koha::Patrons' } );
    my $patron2 = $builder->build_object( { class => 'Koha::Patrons' } );

    my $event = new_event( actor_id => $actor->id );
    is( $event->subject_count, 0, 'event starts empty' );
    $event->add_api_subject( { patron_id => $patron2->id, fields => [ 'email', 'surname' ] } );
    $event->add_subject( { patron_id => $patron1->id, data_classes => ['profile'] } );
    $event->add_api_subject( { patron_id => $patron2->id, fields => [ 'surname', 'category_id' ] } );
    is( $event->subject_count, 2, 'subjects are deduplicated within the event' );

    my $event_id = $event->commit;
    like( $event_id, qr/\A[0-9a-f-]{36}\z/i, 'server UUID is returned' );
    is( disclosure_logs()->count, 2, 'one row is stored per unique patron' );

    my @logs = disclosure_logs()->as_list;
    is_deeply(
        [ map { $_->object } @logs ], [ sort { $a <=> $b } ( $patron1->id, $patron2->id ) ],
        'rows are deterministic by patron ID'
    );

    for my $log (@logs) {
        is( $log->user,      $actor->id, 'actor uses the typed column' );
        is( $log->interface, 'api',      'interface uses the typed column' );
        my $payload = JSON->new->decode( $log->info );
        is_deeply(
            [ sort keys %{$payload} ],
            [ sort qw( v event_id surface breadth data_classes auth_source ) ],
            'payload has only the closed keys'
        );
        is( $payload->{event_id}, $event_id,                              'rows share one event ID' );
        is( $log->info,           JSON->new->canonical->encode($payload), 'payload JSON is canonical' );
    }

    my ($patron2_log) = grep { $_->object == $patron2->id } @logs;
    is_deeply(
        JSON->new->decode( $patron2_log->info )->{data_classes},
        [ 'contact', 'identity', 'profile' ],
        'classes are unioned and sorted per patron'
    );
    is( scalar @{ $logger->messages }, 1, 'one logger message is emitted after the event commit' );
    my ($logger_payload) = $logger->messages->[0] =~ /\APATRON DISCLOSURE EVENT: (.*)\z/;
    my $logger_data = JSON->new->decode($logger_payload);
    is_deeply(
        [ sort keys %{$logger_data} ],
        [ sort qw( event_id surface breadth auth_source subject_count ) ],
        'logger payload contains only event-level metadata'
    );
    is( $logger_data->{subject_count}, 2,         'logger payload contains the aggregate subject count' );
    is( $event->commit,                $event_id, 'a repeated commit returns the existing event ID' );
    is( disclosure_logs()->count,      2,         'a repeated commit writes no duplicate rows' );

    $schema->storage->txn_rollback;
    done_testing;
};

subtest 'sequential events are never deduplicated' => sub {
    plan tests => 4;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog',         1 );
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureMaxSubjects', 1000 );
    @{ $logger->messages } = ();

    my $actor  = $builder->build_object( { class => 'Koha::Patrons' } );
    my $patron = $builder->build_object( { class => 'Koha::Patrons' } );

    my @event_ids;
    for ( 1 .. 2 ) {
        my $event = new_event( actor_id => $actor->id );
        $event->add_subject( { patron_id => $patron->id, data_classes => ['identity'] } );
        push @event_ids, $event->commit;
    }

    isnt( $event_ids[0], $event_ids[1], 'sequential events have distinct server IDs' );
    is( disclosure_logs()->count,      2, 'both requests remain in the audit trail' );
    is( scalar @{ $logger->messages }, 2, 'each committed event emits one logger message' );
    is_deeply(
        [ map { JSON->new->decode( $_->info )->{event_id} } disclosure_logs()->as_list ],
        \@event_ids,
        'stored events retain request order'
    );

    $schema->storage->txn_rollback;
};

subtest 'subject limit and failed inserts disclose no partial audit event' => sub {
    plan tests => 6;

    $schema->storage->txn_begin;
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog',         1 );
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureMaxSubjects', 1 );
    @{ $logger->messages } = ();

    my $actor   = $builder->build_object( { class => 'Koha::Patrons' } );
    my $patron1 = $builder->build_object( { class => 'Koha::Patrons' } );
    my $patron2 = $builder->build_object( { class => 'Koha::Patrons' } );
    my $event   = new_event( actor_id => $actor->id );
    $event->add_subject( { patron_id => $patron1->id, data_classes => ['identity'] } );
    $event->add_subject( { patron_id => $patron2->id, data_classes => ['identity'] } );

    throws_ok { $event->commit } qr/configured maximum is 1/, 'an oversized exact event is rejected';
    is( disclosure_logs()->count,      0, 'the subject limit writes no partial event' );
    is( scalar @{ $logger->messages }, 0, 'the subject limit emits no logger message' );

    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureMaxSubjects', 1000 );
    my $store_calls     = 0;
    my $store           = Koha::ActionLog->can('store');
    my $action_log_mock = Test::MockModule->new('Koha::ActionLog');
    $action_log_mock->redefine(
        store => sub {
            my $self = shift;
            die "injected second-row failure\n" if ++$store_calls == 2;
            return $store->( $self, @_ );
        }
    );

    throws_ok { $event->commit } qr/injected second-row failure/,
        'a later row failure escapes to the response boundary';
    is( disclosure_logs()->count,      0, 'the transaction rolls back the earlier row' );
    is( scalar @{ $logger->messages }, 0, 'a rolled-back event emits no logger message' );

    $schema->storage->txn_rollback;
};

had_no_warnings;
done_testing;
