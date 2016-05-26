#!/usr/bin/perl
# vim: se ts=4 et syn=perl:

# check_end2end.pl - Simple configurable end-to-end probe plugin for Nagios
#
#     Copyright (C) 2016 Giacomo Montagner <giacomo@entirelyunlike.net>
#
#     This program is free software: you can redistribute it and/or modify
#     it under the same terms as Perl itself, either Perl version 5.8.4 or,
#     at your option, any later version of Perl 5 you may have available.
#
#     This program is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
#
#
#   CHANGELOG:
#
#       2016-05-19T08:46:55+0200
#           First release.
#
#       2016-05-24T11:13:44+0200 v1.0.1
#           - Removed "Export" as parent to Monitoring::Plugin::End2end;
#           - Added TODO to make steps optional
#
#       2016-05-25T09:06:44+0200 v1.0.2
#           - Filled in contact/bug/copyright details in perl POD documentation
#
#       2016-05-26T14:19:26+0200 v1.1.0
#           - Added support for "on_failure" configuration directive
#           - Added more documentation about configuration file format
#
#
#


use strict;
use warnings;
use version; our $VERSION = qv(1.1.0);
use v5.010.001;
use utf8;
use File::Basename qw(basename);

use Config::General;
use Monitoring::Plugin;
use LWP::UserAgent;
use Time::HiRes qw(time);

use subs qw(
    debug
);








# ------------------------------------------------------------------------------
#  Globals
# ------------------------------------------------------------------------------
my $plugin_name = basename( $0 );




# ------------------------------------------------------------------------------
#  Command line initialization and parsing
# ------------------------------------------------------------------------------

# This plugin's initialization - see https://metacpan.org/pod/Monitoring::Plugin
#   --verbose, --help, --usage, --timeout and --host are defined automatically.
my $np = Monitoring::Plugin::End2end->new(
    usage => "Usage: %s [-v|--verbose] [-t <timeout>] [-d|--debug] [-M|--manual] "
          . "[-c|--critical=<threshold>] [-w|--warning=<threshold>] "
          . "[-C|--totcritical=<threshold>] [-W|--totwarning=<threshold>] "
          . "-f|--configFile=<cfgfile>",
    version => $VERSION,
    blurb   => "This plugin uses LWP::UserAgent to fake a website navigation"
                . " as configured in the named configuration file.",
);

# Command line options
$np->add_arg(
    spec => 'debug|d',
    help => qq{-d, --debug\n   Print debugging messages to STDERR. }
          . qq{Package Data::Dumper is required for debug.},
);

$np->add_arg(
    spec => 'warning|w=s',
    help => qq{-w, --warning=INTEGER:INTEGER\n}
          . qq{   Warning threshold for each single step.\n}
          . qq{   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT }
          . qq{for the threshold format, or run $plugin_name -M (requires perldoc executable).},
);

$np->add_arg(
    spec => 'critical|c=s',
    help => qq{-c, --critical=INTEGER:INTEGER\n}
          . qq{   Critical threshold for each single step.\n}
          . qq{   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT }
          . qq{for the threshold format, or run $plugin_name -M (requires perldoc executable). },
);

$np->add_arg(
    spec => 'totwarning|W=s',
    help => qq{-W, --totwarning=INTEGER:INTEGER\n}
          . qq{   Warning threshold for the whole process.\n}
          . qq{   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT }
          . qq{for the threshold format, or run $plugin_name -M (requires perldoc executable).},
);

$np->add_arg(
    spec => 'totcritical|C=s',
    help => qq{-C, --totcritical=INTEGER:INTEGER\n}
          . qq{   Critical threshold for the whole process.\n}
          . qq{   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT }
          . qq{for the threshold format, or run $plugin_name -M (requires perldoc executable). },
);

$np->add_arg(
    spec => 'configFile|f=s',
    help => qq{-f, --configFile=/path/to/file.\n   Configuration }
          . qq{of the steps to be performed by this plugin. }
          . qq{See "perldoc $plugin_name" for details con configuration format, }
          . qq{or run $plugin_name -M},
);

$np->add_arg(
    spec => 'useEnvVars|e',
    help => qq{-e, --useEnvVars\n}
          . qq{   Interpolate variables in configuration file using enviroment variables }
          . qq{also. Default: NO. },
);

$np->add_arg(
    spec => 'allowEmptyVars|E',
    help => qq{-E, --allowEmptyVars\n}
          . qq{   By default, Config::General will croak if it tries to interpolate an }
          . qq{undefined variable. Use this option to turn off this behaviour.},
);

$np->add_arg(
    spec => 'var=s@',
    help => qq{--var <VAR=VALUE>\n}
          . qq{   Specify this option (even multiple times) to pass variables to this }
          . qq{plugin on the command line. These variables will be interpolated in the }
          . qq{configuration file, as if they were found inside environment. This automatically }
          . qq{turns on --useEnvVars flag.},
);

$np->add_arg(
    spec => 'manual|M',
    help => qq{-M, --manual\n   Show plugin manual (requires perldoc executable).},
);

# Parse @ARGV and process standard arguments (e.g. usage, help, version)
$np->getopts;
my $opts = $np->opts();

if ($opts->manual()) {
    exec(qq{\$(which perldoc) $0});
}

if ($opts->debug) {
    require Data::Dumper;
    *debug = sub { say STDERR "DEBUG :: ", @_; };
    *ddump = sub { Data::Dumper->Dump( @_ ); };
} else {
    *debug = sub { return; };
    *ddump = *debug;
}

unless ($opts->configFile()) {
    $np->plugin_die("Missing mandatory option: --configFile|-f");
}

my $useEnv = $opts->useEnvVars();
if (defined( my $vars = $opts->var() )) {
    $useEnv = 1;
    $np->plugin_die("Cannot parse variables passed via --var flag")
        unless ref( $vars ) && ref( $vars ) eq 'ARRAY';

    for my $vardef (@$vars) {
        my ($name, $val) = split('=', $vardef, 2);
        $np->plugin_die("Cannot parse variable definition: $vardef")
            unless defined($name) && defined($val);

        $ENV{$name} = $value;
    }
}


# ------------------------------------------------------------------------------
#  External configuration loading
# ------------------------------------------------------------------------------

# Read configuration file
my $conf = Config::General->new(
    -ConfigFile      => $opts->configFile(),
    -InterPolateVars => 1,
    -InterPolateEnv  => $useEnv,
    -StrictVars      => ! $opts->allowEmptyVars(),
    -ExtendedAccess  => 1,
);

if ($conf->exists("Monitoring::Plugin::shortname")) {
    $np->shortname( $conf->value("Monitoring::Plugin::shortname") );
}





# ------------------------------------------------------------------------------
#  MAIN :: Do the check
# ------------------------------------------------------------------------------

# Perform each configured step
my $ua = LWP::UserAgent->new(
    agent      => $conf->exists("LWP::UserAgent::agent") ? $conf->value("LWP::UserAgent::agent") : "$plugin_name",
    cookie_jar => { },
    # TODO: be more configurable
);

my $steps = Steps->new( $conf->hash("Step") );

# Check for thresholds before performing steps
my @step_names = $steps->list();
my $num_steps = @step_names;

my $warns = Thresholds->new( $opts->warning(),  @step_names );
debug "WARNING THRESHOLDS: ", ddump([$warns]);
my $crits = Thresholds->new( $opts->critical(), @step_names );
debug "CRITICAL THRESHOLDS: ", ddump([$crits]);


# Now for the real check
if ($opts->timeout()) {
    $SIG{ALRM} = sub {
        $np->plugin_die("Operation timed out after ". $opts->timeout(). "s" );
    };

    alarm $opts->timeout();
}

# TODO: make steps optional by specifying some configuration variable like
# "on_failure = WARNING"

my $totDuration = 0;
for my $step_name ( @step_names ) {

    debug "Performing step: ", $step_name;

    my $step = $steps->step( $step_name )
        or $np->plugin_die("Malformed configuration file -- cannot proceed on step $step_name; error token was: ". $Step::reason);

    debug "URL: ", $step->url();
    debug "Data: ", ddump([ $step->data() ])
        if $step->data();
    debug "Method: ", $step->method();

    my $response;
    my $method = $step->method();

    my $before = time();
    if (defined( $step->data() )) {
        $response = $ua->$method(
            $step->url(),
            $step->data(),
        );
    } else {
        $response = $ua->$method( $step->url() );
    }
    my $after = time();

    my $duration = sprintf("%.3f", $after - $before);
    $totDuration += $duration;
    my $warn = $warns->get( $step_name );
    my $crit = $crits->get( $step_name );

    if ($response->is_success) {
        $np->add_perfdata( label => "Step_${step_name}_duration", value => $duration, uom => "s", warning => $warn, critical => $crit );
        my $status = $np->check_threshold( check => $duration, warning => $warn, critical => $crit );

        if ($status == OK) {
            $np->add_ok( "Step $step_name took ${duration}s" );
        } elsif ($status == WARNING) {
            $np->add_warning( "Step $step_name took ${duration}s > ${warn}s" );
        } elsif ($status == CRITICAL) {
            $np->add_critical( "Step $step_name took ${duration}s > ${crit}s" );
        }
    }
    else {

        my $level = $step->on_failure();

        if ($level == OK) {
            $np->add_ok( "Step $step_name failed (". $response->status_line(). ") but was ignored as configured" );
        } elsif ($level == WARNING) {
            $np->raise_status( WARNING );
            $np->add_warning( "Step $step_name failed (". $response->status_line(). ")" );
        } else {
            $np->plugin_exit($level, "Step $step_name failed (". $response->status_line(). ")" );
        }
    }

}



# Prepare for exit
my $msg = 'Check complete. ';

# Check total duration time against thresholds
my $tc = $opts->totcritical() || '';
my $tw = $opts->totwarning()  || '';
$np->add_perfdata( label => "Total_duration", value => $totDuration, uom => "s", warning => $tw, critical => $tc );

my $status = $np->check_threshold( check => $totDuration, warning => $tw, critical => $tc );

if ( $status == CRITICAL ) {
    $msg .= "CRITICAL: Total duration was ${totDuration}s > ${tc}s; ";
    $np->raise_status( CRITICAL );
} elsif ( $status == WARNING ) {
    $msg .= "WARNING Total duration was ${totDuration}s > ${tw}s; ";
    $np->raise_status( WARNING );
}

# Build final message
my @crits = $np->criticals();
$msg .= "CRITICAL steps: ". join("; ", @crits). "; "
    if @crits;

my @warns = $np->warnings();
$msg .= "WARNING steps: ". join("; ", @warns). "; "
    if @warns;

my @oks = $np->oks();
$msg .= "Steps OK: ". join("; ", @oks). "; "
    if @oks;

# Finally, exit
$np->plugin_exit( $np->status(), $msg );













###############################################################################
## Monitoring::Plugin extension
###############################################################################
package Monitoring::Plugin::End2end;

use strict;
use warnings;
use Monitoring::Plugin;
use parent qw(
    Monitoring::Plugin
);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    $self->{_end2end_status} = 0;
    $self->{_end2end_oks} = [];
    $self->{_end2end_warnings} = [];
    $self->{_end2end_criticals} = [];

    return $self;
}


sub add_warning {
    my $self = shift;

    push @{ $self->{_end2end_warnings} }, @_;

    $self->{_end2end_status} = WARNING
        unless $self->{_end2end_status} && $self->{_end2end_status} > WARNING;
}

sub add_critical {
    my $self = shift;

    push @{ $self->{_end2end_criticals} }, @_;

    $self->{_end2end_status} = CRITICAL
        unless $self->{_end2end_status} && $self->{_end2end_status} > CRITICAL;
}

sub add_ok {
    my $self = shift;

    push @{ $self->{_end2end_oks} }, @_;
}

sub status {
    return $_[0]->{_end2end_status};
}

sub raise_status {
    my ($self, $newStatus) = @_;
    $self->{_end2end_status} = $newStatus
        if $self->{_end2end_status} < $newStatus;
}

sub oks {
    return wantarray                    ?
        @{ $_[0]->{_end2end_oks} } :
           $_[0]->{_end2end_oks}   ;
}

sub warnings {
    return wantarray                    ?
        @{ $_[0]->{_end2end_warnings} } :
           $_[0]->{_end2end_warnings}   ;
}

sub criticals {
    return wantarray                    ?
        @{ $_[0]->{_end2end_criticals} } :
           $_[0]->{_end2end_criticals}   ;
}





###############################################################################
## DATA HANDLER
###############################################################################

package Data;

use strict;
use warnings;
use URI::URL;

sub new {
    my $class = shift;
    my $url = URI::URL->new("?".$_[0]);

    return bless( { $url->query_form() }, $class );
}



###############################################################################
## STEP HANDLER
###############################################################################

package Step;

use strict;
use warnings;
use Monitoring::Plugin;

sub new {
    my $class = shift;
    return unless ref( $_[0] ) && ref( $_[0] ) eq 'HASH';

    my $step = {};

    # In case of errors, do not initialize this object
    # (will cause the plugin to die with an error)
    unless ( $step->{url} = delete $_[0]->{url} ) {
        our $reason = "missing 'url' directive";
        return;
    }

    # Parse binary data if present
    if (defined( my $data = delete $_[0]->{binary_data})) {
        unless ( $step->{data} = Data->new( $data ) ) {
            our $reason = "parsing 'binary_data' failed";
            return;
        }
    }

    # Parse on_failure directive if present, otherwise force it
    # to CRITICAL
    if (exists( $_[0]->{on_failure} )) {
        eval {
            # Call OK(), WARNING(), CRITICAL() or UNKNOWN()
            no strict "refs";
            my $m = uc( $_[0]->{on_failure} );
            $step->{on_failure} = $m->();
        };
        if ($@) {
            our $reason = "parsing 'on_failure' failed (Caused by: $@)";
            return;
        }
    } else {
        $step->{on_failure} = CRITICAL;
    }

    # Parse method if present, otherwise force it to "get"
    $step->{method} = $_[0]->{method} ? lc( $_[0]->{method} ) : 'get';

    return bless( $step, $class );
}


sub url {
    return $_[0]->{url};
}

sub data {
    return unless $_[0]->{data};
    my %data = %{ $_[0]->{data} };
    return \%data;
}

sub method {
    return $_[0]->{method};
}

sub on_failure {
    return $_[0]->{on_failure};
}


###############################################################################
## STEPS HANDLER
###############################################################################

package Steps;

use strict;
use warnings;

sub new {
    my $class = shift;
    return bless({ @_ }, $class);
}


sub step {
    return Step->new( $_[0]->{ $_[1] } );
}

sub list {
    return wantarray                 ?
        sort( keys( %{ $_[0] } ) )    :
        [ sort( keys( %{ $_[0] } ) ) ];
}






###############################################################################
## THRESHOLDS HANDLER
###############################################################################

package Thresholds;

sub new {
    my $class = shift;
    my $val   = shift || '';
    my @names = @_;

    my %thr;
    if ($val =~ /,/) {
        my @thr = split(/\s*,\s*/, $val);
        %thr = map { $names[ $_ ] => (defined( $thr[ $_ ] ) ? $thr[ $_ ] : '') } 0..$#names;
    } else {
        %thr = map { $names[ $_ ] => $val } 0..$#names;
    }

    return bless( \%thr, $class );
}




sub get {
    return $_[0]->{ $_[1] };
}






###############################################################################
## MANUAL
###############################################################################

=pod

=head1 NAME

check_end2end.pl - Simple configurable end-to-end probe plugin for Nagios


=head1 VERSION

This is the documentation for check_end2end.pl v1.1.0


=head1 SYNOPSYS

See check_end2end.pl -h


=head1 THE CHECK

Every step configured in the configuration file (see L<CONFIGURATION FILE
FORMAT>) is performed regardless of the fact that you specify a threshold for
that step, a global threshold, or a single thresold that will be applied to
every step, because B<every step is checked for success or failure>.
A step check is considered successful if LWP::USerAgent's C<is_success()> method
returns true; otherwise, the check is considered as failed.

A failure in one of the steps will cause the immediate exit of the plugin, with
a critical status, unless configured otherwise (again, see L<CONFIGURATION FILE
FORMAT>), while, if one or more steps are above their time thresholds,
the check will continue and perform the remaining steps (unless the global
timeout is reached). See L<THRESHOLD FORMATS> for details about timing
thresholds.

Overall status of the check will be reported at the end.


=head1 THRESHOLD FORMATS

=head2 -C <CRIT>, -W <WARN>

Total-duration thresholds are just single values in the format specified by
L<https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT>.
For example:

    -W 0.200:1.0

will give a warning if the total duration of the process is below 0.2s or
above 1.0s.


=head2 -c <crit>, -w <warn>

These are per-step duration thresholds. B<If only one value is specified,
that value will be applied to ALL steps in the process>, one by one.
The values still follow the format at
L<https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT>.

For example:

    -c 3

will give you a critical if B<any one> of the steps in you process will last
more than 3s (or less than 0 but that would mean your clock reset in the middle
of the process).

But single-steps thresholds can be specified as a B<comma-separated list of
values>; each individual value follows the already-named guidelines, and
omitted values will be taken as no-threshold for the corresponding step.
The thresholds are appled in order.

So, for example, if you have a 5-step check and only want to apply check to
some steps, you will have to specify:

    -w ,0.2,,,0.5 -c ,0.6,1.1

This will apply a warning threshold of 0.2s and a critical threshold of 0.6s
to the second step, a warning threshold of 0.5s to the fifth step, and a
critical threshold of 1.1s to the third step.

=head3 B<Omitting trailing commas>

You can omit trailing commas if you specify at least two values and don't need
others. For example, to specify thresholds only for the first two steps of a
7-steps process:

    -w 1,3 -c 3,6

will perform all the configured checks, but only the first and the second will
be checked against their thresholds. If you want to apply thresholds only to
the first step, you have to provide at least one trailing comma:

    -w 0.7,

speficies a warning threshold of 0.7s only for the first step.


=head1 CONFIGURATION FILE FORMAT

Here's a sample configuration file for this plugin

    #
    # login.cfg -- Configuration file for login check on www.example.com
    #


    ########## check_end2end -specific configuration directives
    #
    # Optional - override default "END2END" plugin name in outputs
    Monitoring::Plugin::shortname = "Check www.example.com Login"

    ########## LWP::UserAgent -specific configuration directives
    #
    # Optional - Override useragent string - defaults to check_end2end
    LWP::UserAgent::agent = "Nagios login check via check_end2end"


    ########## Custom configuration directives
    #
    # Optional - You can specify variables to be interpolated in the
    # following configuration
    BASE_URL = "https://www.example.com"



    ########## check_end2end REQUIRED CONFIGURATION
    #
    # This plugin requires you to specify a list of subsequent steps to be performed.
    # Steps will be performed IN ALPHABETICAL ORDER, so make sure you give them
    # names according to a proper sequence.
    #
    <Step "00 - Public login page">
        url = "$BASE_URL/login.html"
        method = GET
        on_failure = WARNING
    </Step>

    # Lines can be split as in shell scripts, escaping the final newline with a \
    <Step "01 - Login verification">
        url = "$BASE_URL/login.html"
        binary_data = username=exampleuser&\
            password=examplepassword
        method = POST
    </Step>

    <Step "03 - Private login page">
        url = "$BASE_URL/pri/home.html"
        method = GET
    </Step>


The configuration file is made up of one or many named <Step> blocks, each step
is performed and checked for success. Steps are B<ordered alphabetically>, so
make sure to give them names that reflect the real order to be respected.


=head2 B<Required Step parameters>

=over 4

=item * B<url>

C<url> is the only required parameter for a Step. The url you want to test.

=back


=head2 B<Optional Step parameters>

=over 4

=item * B<method>

C<method> specifies which http method to use to perform the step. B<GET> is the
default. This is passed to LWP::UserAgent after lowercasing it.


=item * B<binary_data>

C<binary_data> is the B<url-encoded> data to be passed to LWP::UserAgent. Prior
to be passed to LWP::UserAgent, binary_data is parsed by the URI::URL module.


=item * B<on_failure>

C<on_failure> specifies if a failure of the Step must be treated as an OK
status, a WARNING, a CRITICAL or ar UNKNOWN.
The default is to treat a failure as a CIRITCAL event and to return an error
immediately.
Specify OK if you just want to time some steps but don't want failures to
be considered as errors; a level of WARNING will raise the level of the check
to WARNING (at least, unless some more serious error happens afterwards); a
level of CRITICAL (default) or UNKNOWN will cause the check to stop as soon
as the error happens and to exit reporting that severity level.

=back


=head1 TODO

Some ideas:

=over 4

=item B<*> Enable environment variables

Allow usage of Nagios enviroment variables in configuration file.


=item B<*> Enable macros

Add a command line switch so that Nagios macros can be used in command line and
be expanded in configuration file.


=back





=head1 PREREQUISITES

Reuired modules:

=over 4

=item * Config::General

=item * LWP::UserAgent

=item * Monitoring::Plugin

=item * URI::URL

=back




=head1 AUTHOR

Giacomo Montagner, <kromg at entirelyunlike.net>,
<kromg.kromg at gmail.com> >

=head1 BUGS AND CONTRIBUTIONS

Please report any bug at L<https://github.com/kromg/nagios-plugins/issues>. If
you have any patch/contribution, feel free to fork git repository and submit a
pull request with your modifications.





=head1 LICENSE AND COPYRIGHT

Copyright (C) 2016 Giacomo Montagner <giacomo@entirelyunlike.net>

This program is free software: you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.4 or,
at your option, any later version of Perl 5 you may have available.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See http://dev.perl.org/licenses/ for more information.


=head1 AVAILABILITY

Latest sources are available from L<https://github.com/kromg/nagios-plugins>

=cut