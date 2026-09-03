#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use File::Find;
use FindBin;
use Test::Exception;
use Test::More;
use Test::NoWarnings qw( had_no_warnings );
use YAML::XS;

use Koha::REST::Plugin::PatronDisclosure;

my $root = "$FindBin::Bin/../..";

my %expected = (
    'GET /patrons' => {
        controller             => 'Patrons#list',
        surface                => 'patrons.search.results',
        strategies             => ['serialized_patrons'],
        max_page_size          => 1000,
        subjects_per_page_item => 1,
    },
    'GET /patrons/{patron_id}' => {
        controller => 'Patrons#get',
        surface    => 'patrons.record.api',
        strategies => ['serialized_patrons'],
    },
    'GET /patrons/{patron_id}/checkouts' => {
        controller             => 'Patrons::Checkouts#list',
        surface                => 'patrons.checkouts.current',
        strategies             => [qw( path_patron serialized_patrons )],
        max_page_size          => 1000,
        subjects_per_page_item => 1,
        fixed_subjects         => 1,
        path_patron            => {
            parameter    => 'patron_id',
            data_classes => [qw( circulation_current identity )],
        },
    },
    'GET /patrons/{patron_id}/holds' => {
        controller => 'Patrons::Holds#list',
        surface    => 'patrons.holds.list',
        strategies => ['explicit'],
    },
    'GET /patrons/{patron_id}/recalls' => {
        controller  => 'Patrons::Recalls#list',
        surface     => 'patrons.recalls.current',
        strategies  => ['path_patron'],
        path_patron => {
            parameter    => 'patron_id',
            data_classes => [qw( circulation_current identity )],
        },
    },
    'GET /bookings' => {
        controller             => 'Bookings#list',
        surface                => 'bookings.search.results',
        strategies             => [qw( patron_references serialized_patrons )],
        max_page_size          => 1000,
        subjects_per_page_item => 2,
    },
    'GET /biblios/{biblio_id}/bookings' => {
        controller             => 'Biblios#get_bookings',
        surface                => 'catalogue.bookings.by_record',
        strategies             => [qw( patron_references serialized_patrons )],
        max_page_size          => 1000,
        subjects_per_page_item => 1,
    },
    'GET /biblios/{biblio_id}/checkouts' => {
        controller             => 'Biblios#get_checkouts',
        surface                => 'catalogue.checkouts.by_record',
        strategies             => [qw( patron_references serialized_patrons )],
        max_page_size          => 1000,
        subjects_per_page_item => 2,
    },
    'GET /biblios/{biblio_id}/items' => {
        controller             => 'Biblios#get_items',
        surface                => 'catalogue.items.patron_status',
        strategies             => [qw( patron_references serialized_patrons )],
        max_page_size          => 1000,
        subjects_per_page_item => 4,
    },
    'GET /biblios/{biblio_id}/pickup_locations' => {
        controller => 'Biblios#pickup_locations',
        surface    => 'catalogue.biblio_pickup_locations.for_patron',
        strategies => ['explicit'],
    },
    'GET /items/{item_id}/pickup_locations' => {
        controller => 'Items#pickup_locations',
        surface    => 'catalogue.item_pickup_locations.for_patron',
        strategies => ['explicit'],
    },
);

my %covered;
for my $file ( glob "$root/api/v1/swagger/paths/*.yaml" ) {
    my $paths = YAML::XS::LoadFile($file);
    for my $path ( sort keys %{$paths} ) {
        next unless ref( $paths->{$path} ) eq 'HASH';
        for my $method (qw( get post put patch delete )) {
            my $operation = $paths->{$path}->{$method};
            next unless ref($operation) eq 'HASH' && exists $operation->{'x-koha-patron-disclosure'};

            my $key           = uc($method) . " $path";
            my $authorization = $operation->{'x-koha-authorization'};
            ok(
                       ref($authorization) eq 'HASH'
                    && exists $authorization->{permissions}
                    && defined $authorization->{permissions},
                "$key has an explicit staff authorization contract"
            );

            my $normalized;
            lives_ok {
                $normalized = Koha::REST::Plugin::PatronDisclosure::_normalize_metadata(
                    $operation->{'x-koha-patron-disclosure'},
                    $operation
                );
            }
            "$key has valid patron-disclosure metadata";

            my $metadata = {
                controller => $operation->{'x-mojo-to'},
                surface    => $normalized->{surface},
                strategies => [ sort keys %{ $normalized->{strategies} } ],
            };
            $metadata->{max_page_size} = $normalized->{max_page_size}
                if defined $normalized->{max_page_size};
            $metadata->{subjects_per_page_item} = $normalized->{subjects_per_page_item}
                if defined $normalized->{subjects_per_page_item};
            $metadata->{fixed_subjects} = $normalized->{fixed_subjects}
                if $normalized->{fixed_subjects};
            $metadata->{path_patron} = $normalized->{path_patron} if $normalized->{path_patron};
            $covered{$key} = $metadata;

            if ( defined $normalized->{max_page_size} ) {
                like(
                    $operation->{responses}->{400}->{description} // q{},
                    qr/\bpatron_disclosure_page_size_exceeded\b/,
                    "$key documents its audit page-size rejection"
                );
            }
            if ( my $path_patron = $normalized->{path_patron} ) {
                like(
                    $path,
                    qr/\{\Q$path_patron->{parameter}\E\}/,
                    "$key declares the configured path patron parameter"
                );
            }
        }
    }
}

is_deeply( \%covered, \%expected, 'the checked-in REST coverage manifest is exact' );

my %expected_cgi = (
    'circ/circulation.pl'            => ['circulation.checkout'],
    'members/alert-subscriptions.pl' => ['patrons.alerts.list'],
    'members/accountline-details.pl' => ['patrons.account.line_details'],
    'members/boraccount.pl'          => ['patrons.account.transactions'],
    'members/holdshistory.pl'        => ['patrons.holds.history'],
    'members/memberentry.pl'         =>
        [qw( patrons.record.create_form patrons.record.duplicate patrons.record.duplicate_match patrons.record.edit )],
    'members/moremember.pl'           => [qw( patrons.record.brief patrons.record.details )],
    'members/notices.pl'              => ['patrons.notices.list'],
    'members/pay.pl'                  => ['patrons.account.outstanding'],
    'members/purchase-suggestions.pl' => ['patrons.suggestions.list'],
    'members/readingrec.pl'           => ['patrons.circulation.history'],
    'members/recallshistory.pl'       => ['patrons.recalls.history'],
    'members/routing-lists.pl'        => ['patrons.routing_lists.list'],
    'members/statistics.pl'           => ['patrons.statistics.summary'],
);

my @actual_cgi;
find(
    sub {
        return unless /\.pl\z/;
        open my $fh, '<', $File::Find::name or die "Cannot read $File::Find::name: $!";
        local $/;
        my $source = <$fh>;
        close $fh;
        return unless $source =~ /patron_disclosure\s*=>/;
        ( my $relative = $File::Find::name ) =~ s{^\Q$root/\E}{};
        push @actual_cgi, $relative;
    },
    "$root/circ",
    "$root/members",
);

is_deeply( [ sort @actual_cgi ], [ sort keys %expected_cgi ], 'the checked-in CGI coverage manifest is exact' );

for my $file ( sort keys %expected_cgi ) {
    open my $fh, '<', "$root/$file" or die "Cannot read $file: $!";
    local $/;
    my $source = <$fh>;
    close $fh;

    like( $source, qr/use Koha::Patron::Disclosure;/,      "$file loads the shared disclosure contract" );
    like( $source, qr/output_html_with_http_headers\s*\(/, "$file uses the buffered output boundary" );
    like( $source, qr/Koha::Patron::Disclosure->enabled/,  "$file gates audit-only work when logging is disabled" );
    if ( $file eq 'members/readingrec.pl' ) {
        like(
            $source,
            qr/if\s*\(\s*\$op\s+eq\s+'export_barcodes'.*?print\s+\$input->header/s,
            "$file confines its direct header to the explicitly deferred barcode export"
        );
    } else {
        unlike( $source, qr/print\s+\$\w+->header/, "$file has no direct header before its audit boundary" );
    }
    for my $surface ( @{ $expected_cgi{$file} } ) {
        like( $source, qr/'\Q$surface\E'/, "$file declares stable surface $surface" );
    }

    if ( $file eq 'circ/circulation.pl' || $file eq 'members/moremember.pl' ) {
        unlike(
            $source,
            qr/\$patron_messages->get_column\('manager_id'\)->all/,
            "$file does not treat Koha::Objects->get_column as a DBIx resultset"
        );
    }

    if ( $file eq 'members/moremember.pl' ) {
        like(
            $source,
            qr/my \@message_manager_ids;\s*if \(\$patron_disclosure_enabled\) \{\s*\@message_manager_ids = grep \{ defined \$_ \}\s*\$patron_messages->get_column\('manager_id'\);\s*\}/s,
            "$file discovers message managers inside an explicit enabled branch"
        );
    }
}

my %expected_svc = (
    'svc/checkouts'     => [qw( patrons.checkouts.current patrons.checkouts.current_batch )],
    'svc/holds'         => ['patrons.holds.list'],
    'svc/return_claims' => ['patrons.return_claims.list'],
);

my @actual_svc;
find(
    sub {
        return if -d $File::Find::name;
        open my $fh, '<', $File::Find::name or die "Cannot read $File::Find::name: $!";
        local $/;
        my $source = <$fh>;
        close $fh;
        return unless $source =~ /patron_disclosure\s*=>/;
        ( my $relative = $File::Find::name ) =~ s{^\Q$root/\E}{};
        push @actual_svc, $relative;
    },
    "$root/svc",
);

is_deeply(
    [ sort @actual_svc ], [ sort keys %expected_svc ],
    'the checked-in legacy service coverage manifest is exact'
);

for my $file ( sort keys %expected_svc ) {
    open my $fh, '<', "$root/$file" or die "Cannot read $file: $!";
    local $/;
    my $source = <$fh>;
    close $fh;

    like( $source, qr/use Koha::Patron::Disclosure;/,     "$file loads the shared disclosure contract" );
    like( $source, qr/output_with_http_headers\s*\(/,     "$file uses the buffered output boundary" );
    like( $source, qr/Koha::Patron::Disclosure->enabled/, "$file gates audit-only work when logging is disabled" );
    unlike( $source, qr/print\s+\$input->header/, "$file does not emit headers before its audit commit" );
    for my $surface ( @{ $expected_svc{$file} } ) {
        like( $source, qr/'\Q$surface\E'/, "$file declares stable surface $surface" );
    }

    if ( $file eq 'svc/return_claims' ) {
        unlike( $source, qr/resolved_by_data\s*=\s*\$patron->unblessed/, 'resolver output is explicitly allowlisted' );
        like( $source, qr/borrowernumber\s*=>\s*\$patron->borrowernumber/, 'resolver output retains its identifier' );
        like( $source, qr/firstname\s*=>\s*\$patron->firstname/,           'resolver output retains first name' );
        like( $source, qr/surname\s*=>\s*\$patron->surname/,               'resolver output retains surname' );
    }
}

my %controller_files = (
    Patrons              => 'Koha/REST/V1/Patrons.pm',
    'Patrons::Checkouts' => 'Koha/REST/V1/Patrons/Checkouts.pm',
    'Patrons::Holds'     => 'Koha/REST/V1/Patrons/Holds.pm',
    'Patrons::Recalls'   => 'Koha/REST/V1/Patrons/Recalls.pm',
    Biblios              => 'Koha/REST/V1/Biblios.pm',
    Bookings             => 'Koha/REST/V1/Bookings.pm',
    Items                => 'Koha/REST/V1/Items.pm',
);

for my $coverage ( values %expected ) {
    my ( $controller, $action ) = split /#/, $coverage->{controller}, 2;
    open my $fh, '<', "$root/$controller_files{$controller}" or die "Cannot read controller: $!";
    local $/;
    my $source = <$fh>;
    close $fh;

    my ($action_source) = $source =~ /^sub \Q$action\E\s*\{(.*?)(?=^sub \w+\s*\{|\z)/ms;
    ok( defined $action_source, "$coverage->{controller} source is discoverable" );
    next unless defined $action_source;

    $action_source =~ s/\$c\s*->\s*objects\s*->\s*to_api//g;
    unlike(
        $action_source,
        qr/->\s*to_api\b/,
        "$coverage->{controller} has no direct serializer bypass"
    );
}

open my $v1_fh, '<', "$root/Koha/REST/V1.pm" or die "Cannot read Koha::REST::V1: $!";
local $/;
my $v1_source = <$v1_fh>;
close $v1_fh;
like(
    $v1_source,
    qr/Convert JSON to XML.*?\$c->res->body\(\$xml\).*?\$c->patron_disclosure->finalize/s,
    'REST finalization remains after XML response conversion'
);

my %table_guard_expectations = (
    'koha-tmpl/intranet-tmpl/prog/en/includes/patron-search.inc' => {
        operation => 'GET /patrons',
        pattern   => qr/Math\.min\(\s*([0-9]+),\s*configured_patron_disclosure_search_max_subjects\s*\)/,
    },
    'koha-tmpl/intranet-tmpl/prog/en/includes/html_helpers/tables/items/catalogue_detail.inc' => {
        operation => 'GET /biblios/{biblio_id}/items',
        pattern   =>
            qr/Math\.min\(\s*([0-9]+),\s*Math\.floor\(\s*configured_patron_disclosure_item_max_subjects\s*\/\s*([0-9]+)\s*\)\s*\)/,
    },
    'koha-tmpl/intranet-tmpl/prog/en/modules/circ/pendingbookings.tt' => {
        operation => 'GET /bookings',
        pattern   =>
            qr/Math\.min\(\s*([0-9]+),\s*Math\.floor\(\s*configured_patron_disclosure_bookings_max_subjects\s*\/\s*([0-9]+)\s*\)\s*\)/,
    },
    'koha-tmpl/intranet-tmpl/prog/en/modules/bookings/list.tt' => {
        operation => 'GET /biblios/{biblio_id}/bookings',
        pattern   => qr/Math\.min\(\s*([0-9]+),\s*configured_patron_disclosure_biblio_bookings_max_subjects\s*\)/,
    },
);

for my $file ( sort keys %table_guard_expectations ) {
    open my $fh, '<', "$root/$file" or die "Cannot read $file: $!";
    local $/;
    my $source = <$fh>;
    close $fh;
    like( $source, qr/pageSizeLimit:/,      "$file constrains its disclosure-audited DataTable" );
    like( $source, qr/Number\.isInteger\(/, "$file handles an invalid subject-limit preference without throwing" );

    my $guard     = $table_guard_expectations{$file};
    my @constants = $source =~ $guard->{pattern};
    ok( @constants, "$file exposes inspectable page-size constants" );
    is(
        $constants[0],
        $expected{ $guard->{operation} }->{max_page_size},
        "${file}'s hard cap matches its OpenAPI disclosure metadata"
    );
    if ( @constants > 1 ) {
        is(
            $constants[1],
            $expected{ $guard->{operation} }->{subjects_per_page_item},
            "${file}'s fan-out divisor matches its OpenAPI disclosure metadata"
        );
    }
}

for my $file (
    'koha-tmpl/intranet-tmpl/prog/en/modules/members/moremember.tt',
    'koha-tmpl/intranet-tmpl/prog/en/modules/circ/circulation.tt'
    )
{
    open my $fh, '<', "$root/$file" or die "Cannot read $file: $!";
    local $/;
    my $source = <$fh>;
    close $fh;
    like(
        $source,
        qr/Math\.min\(\s*1000,\s*Math\.floor\(\s*configured_patron_disclosure_bookings_max_subjects\s*\/\s*2\s*\)\s*\)/,
        "$file supplies the global bookings table ceiling"
    );
}

open my $bookings_js_fh, '<', "$root/koha-tmpl/intranet-tmpl/prog/js/tables/bookings.js"
    or die "Cannot read bookings.js: $!";
local $/;
my $bookings_js_source = <$bookings_js_fh>;
close $bookings_js_fh;
like(
    $bookings_js_source,
    qr/pageSizeLimit:\s*patron_disclosure_bookings_page_size_limit/,
    'the patron bookings table applies its disclosure page-size ceiling'
);

open my $booking_modal_fh, '<', "$root/koha-tmpl/intranet-tmpl/prog/js/modals/place_booking.js"
    or die "Cannot read place_booking.js: $!";
local $/;
my $booking_modal_source = <$booking_modal_fh>;
close $booking_modal_fh;
like(
    $booking_modal_source, qr/function fetchAllKohaApiPages\b/,
    'booking availability fetches complete bounded pages'
);
unlike( $booking_modal_source, qr/_per_page=-1/, 'booking availability does not bypass disclosure page ceilings' );

open my $datatables_fh, '<', "$root/koha-tmpl/intranet-tmpl/prog/js/datatables.js"
    or die "Cannot read datatables.js: $!";
local $/;
my $datatables_source = <$datatables_fh>;
close $datatables_fh;
like(
    $datatables_source, qr/function _dt_apply_page_size_limit\b/,
    'the shared DataTable page-size guard is installed'
);
like( $datatables_source, qr/state\.length = limit/, 'saved DataTable state cannot restore an unsafe page size' );

open my $viewlog_fh, '<', "$root/koha-tmpl/intranet-tmpl/prog/js/viewlog.js"
    or die "Cannot read viewlog.js: $!";
local $/;
my $viewlog_source = <$viewlog_fh>;
close $viewlog_fh;
like(
    $viewlog_source,
    qr/mod == "PATRON_DISCLOSURE"/,
    'the action-log viewer renders disclosure objects as patron links'
);

open my $circ_menu_fh, '<', "$root/koha-tmpl/intranet-tmpl/prog/en/includes/circ-menu.inc"
    or die "Cannot read circ-menu.inc: $!";
local $/;
my $circ_menu_source = <$circ_menu_fh>;
close $circ_menu_fh;
for my $module (qw( MEMBERS CIRCULATION APIKEYS PATRON_DISCLOSURE )) {
    like(
        $circ_menu_source,
        qr/modules=\Q$module\E/,
        "the patron audit link includes $module events"
    );
}

open my $viewlog_tt_fh, '<', "$root/koha-tmpl/intranet-tmpl/prog/en/modules/tools/viewlog.tt"
    or die "Cannot read viewlog.tt: $!";
local $/;
my $viewlog_tt_source = <$viewlog_tt_fh>;
close $viewlog_tt_fh;
like(
    $viewlog_tt_source,
    qr/\[%\s*FOREACH\s+module_name\s+IN\s+modules\s*%\].*?name="modules"\s+value="\[%\s*module_name\s*\|\s*html\s*%\]".*?\[%\s*END\s*%\]/s,
    'the patron audit filter preserves every module supplied by its entrypoint'
);
unlike(
    $viewlog_tt_source,
    qr/\[%\s*ELSE\s*%\]\s*<input[^>]+name="modules"[^>]+value="MEMBERS"[^>]*>\s*<input[^>]+name="modules"[^>]+value="CIRCULATION"/s,
    'the patron audit filter does not replace its module set with a hard-coded subset'
);

had_no_warnings;
done_testing;
