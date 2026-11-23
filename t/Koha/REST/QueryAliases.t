#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;
use utf8;

use JSON qw( from_json to_json );
use Mojo::Parameters;
use Test::More;
use Koha::REST::V1;

my $terms = Mojo::Parameters->new(
    q => to_json( { title => 'luke' } ),
    q => to_json(
        {
            '-and' => [
                { name => { luke    => "%Книга%" } },
                { code => { '-luke' => 'luke' } },
                { title => 'like' },
            ]
        }
    )
);
Koha::REST::V1::_normalize_query_aliases($terms);
is_deeply(
    [ map { from_json($_) } @{ $terms->every_param('q') } ],
    [
        { title => 'luke' },
        {
            '-and' => [
                { name => { like    => "%Книга%" } },
                { code => { '-like' => 'luke' } },
                { title => 'like' },
            ]
        }
    ],
    'Only operator keys change, including nested filters and Unicode terms'
);

my $untouched = Mojo::Parameters->new(
    q => '{"name":{"luke":"x","like":"y"}}',
    q => '{"name":{"luke":'
);
my $original = $untouched->to_string;
Koha::REST::V1::_normalize_query_aliases($untouched);
is( $untouched->to_string, $original, 'Ambiguous or invalid filters are left for query validation' );

my $sort = Mojo::Parameters->new(
    _ordnung_by     => '+surname,-firstname',
    '_ordnung_by[]' => '+title',
    '_ordnung_by[]' => '-item_id',
    _page           => '2'
);
Koha::REST::V1::_normalize_query_aliases($sort);
is_deeply( $sort->every_param('_order_by'),   ['+surname,-firstname'], 'Scalar sorting is restored' );
is_deeply( $sort->every_param('_order_by[]'), [ '+title', '-item_id' ], 'Repeated sort keys keep their order' );
is_deeply( $sort->names, [ '_order_by', '_order_by[]', '_page' ], 'Only canonical parameter names reach the API' );

my $canonical = Mojo::Parameters->new( _order_by => '+name', _ordnung_by => '-name' );
Koha::REST::V1::_normalize_query_aliases($canonical);
is( $canonical->to_string, Mojo::Parameters->new( _order_by => '+name' )->to_string,
    'An alias cannot override explicitly supplied canonical sorting' );

done_testing;
