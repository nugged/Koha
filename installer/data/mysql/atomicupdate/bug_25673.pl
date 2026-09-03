use Modern::Perl;
use Koha::Installer::Output qw( say_success );

return {
    bug_number  => '25673',
    description => 'Add patron data disclosure audit preferences',
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @{$args}{qw( dbh out )};

        $dbh->do(
            q{
                INSERT IGNORE INTO systempreferences (variable, value)
                VALUES
                    ('StaffPatronDataDisclosureLog', '0'),
                    ('StaffPatronDataDisclosureMaxSubjects', '1000')
            }
        );

        say_success( $out, 'Added patron data disclosure audit preferences' );
    },
};
