#!/usr/bin/perl

# We want a more robust test system for the performance and
# functionality tests for HPN-SSH. We will read in a configuration
# file that will contain all of the parameters for the tests
# with results being written to an output file.
# Note1: You *must* have sudo access enabled with NOPASSWD for the user
# running this or run it as root.
# Note2: You *must* make sure you have connected to each of the targets
# at lease once in order to accept the fingerprint.
# Note3: You must use public key authentication with this.

# Config params
# List: releases: Releases to test
# List: ports: Ports corresponding to eahc release
# List: ciphers: Ciphers to use
# List: delays: list of delays to use in tests
# Int: runs: Number of runs
# Int: size: Test data size in GB
# Int: verbose: versbosity levls 1-3
# Int: protocol: 4 or 6 for IPv4 or IPv6
# Bool: bidirectional: Run bidirectional tests
#       Run inbound and outbound if true, outbound only if false
# Char: outfile: Output file
# Char: root: Root directory or installed test versions
# Char: host: Name of host running the test
# Char: interface: name of the interface for synthentic delays
# Char: target: Hostname/IP of target


use Getopt::Long;
use Switch::Back;
use Data::Dumper;
use Socket::More::Interface;
use IPC::Open3;
use Symbol 'gensym';
use PDL;

# Function to trim leading and trailing whitespace
sub trim {
    my ($string) = @_;
    $string =~ s/^\s+//;  # Remove leading whitespace
    $string =~ s/\s+$//;  # Remove trailing whitespace
    return $string;
}

#read and validate the config file
#return hash
sub readConfig {
    $config_file = shift;
    # we need these later
    my $rel_num = 0;
    my $port_num = 0;

    open (my $cfh, '<', $config_file) or
	die "Could not open $config_file for reading. $!";

    while (my $line = <$cfh>) {
	chomp $line;

	#skip if the line is blank
	next if $line =~ /^\s*$/;

	# or starts with #
	next if $line =~ /^s*#/;

	# delete everything after a #
	# for trailing comments
	$line =~ s/#.*$//;

	# split the line at the colon
	($header, $data) = split(":", $line);
	my $header = lc($header);

	given($header) {
	    when ('releases') {
		(@rels) = split(",", $data);
		my $i = 0;
		foreach my $rel (@rels) {
		    $rel = trim($rel);
		    $config{releases}[$i] = $rel;
		    $rel_num = $i;
		    $i++;
		}
	    }
	    when ('ports') {
		(@ports) = split(",", $data);
		my $i = 0;
		foreach my $port (@ports) {
		    $port = trim($port);
		    $config{ports}[$i] = $port;
		    $port_num = $i;
		    $i++;
		}
	    }
	    when ('ciphers') {
		my (@ciphers) = split(",", $data);
		my $i = 0;
		foreach my $cipher (sort @ciphers) {
		    $cipher = trim($cipher);
		    $config{ciphers}[$i] = $cipher;
		    $i++;
		}
	    }
	    when ('runs') {
		$config{runs} = trim($data);
	    }
	    when ('size') {
		$config{size} = trim($data) * 1000;
	    }
	    when ('outfile') {
		$config{outfile} = trim($data);
	    }
	    when ('bidirectional') {
		$config{bidirectional} = trim($data);
	    }
	    when ('root') {
		my $root = trim($data);
		if (! -d $root) {
		    die "Root directory $root not found.";
		}
		$config{root} = $root;
	    }
	    when ('target') {
		$config{target} = trim($data);
	    }
	    when ('delay') {
		my (@delays) = split(",", $data);
		my $i = 0;
		# numerical sort
		foreach my $delay (sort { $a <=> $b } @delays) {
		    $delay = trim($delay);
		    $config{delay}[$i] = $delay;
		    $i++;
		}
	    }
	    when ('protocol') {
		$config{protocol} = "-" . trim($data);
	    }
	    when ('interface') {
		$config{interface} = trim($data);
	    }
	    when ('host') {
		$config{host} = trim($data);
	    }
	    when ('verbose') {
		if (trim($data) == 1) {
		    $config{verbose} = "-v";
		}
		if (trim($data) == 2) {
		    $config{verbose} = "-vv";
		}
		if (trim($data) == 3) {
		    $config{verbose} = "-vvv";
		}
	    }
	}
    }
    # test that the releases actually exist
    foreach my $release (@{$config{releases}}) {
	if (! -d "$config{root}/$release") {
	    die "Release not found at $config{root}/$release\n";
	}
    }

    # if port_num and rel_num are not equal we have too
    # many of one or the other. These must match.
    if ($port_num != $rel_num) {
	die ("You do not have a port for each releases.\nEach release must have a unique port assigned to it.\nNumber of ports: $port_num\nNumber of releases: $rel_num\n");
    }
    if (!$config{protocol}) {
	$config{protocol} = "-4";
    }

    #make sure the interface exists
    if (my $index=if_nametoindex($config{interface}) == 0) {
	die ("The interface $config{interface} does not exist. $!\n");
    }

    #if they specified an outfile on the command line overwrite whatever
    #might be in the configuration
    if ($outfile) {
	$config{outfile} = trim($outfile);
    }
    if (! $config{outfile}) {
	die ("You must provide an output file either on the commandline\nusing --outfile or in the congifuration file\n");
    }

}

sub runTests {
    $bidirectional = shift;
    my %conf = %config;

    #the tests are conducted by a set of nested
    #for loops. We start with the number of runs, then delay, cipher,
    #and the versions we are using

    foreach my $delay (@{$conf{delay}}) {
	#set the rtt delay for this set of runs
	setDelay($delay);
	foreach my $cipher (@{$conf{ciphers}}) {
	    # for some reason we need different arrays for
	    # the sources and destinations probably because of
	    # some oddness in how perl is stepping throught the array
	    # maybe foreach is actually poppping things off the stack?
	    my @sources = my @dests = @{$conf{releases}};
	    foreach my $source (@sources) {
		#index for ports array
		#this will increment in sync with the
		#releases as we step through it
		my $i = 0;
       		foreach my $dest (@dests) {
		    my $port = $conf{ports}[$i];
		    $i++; #we can increment the index for ports here

		    #parse the cipher and make any changes necessary
		    #we need the cipher name and the release to do this
		    my $modified_cipher = setCipher($cipher, $dest);

		    # when we are using OpenSSH we want to use smaller
		    # data sets or the tests take forever.
		    my $size = getSize($conf{size}, $source, $dest, $delay, $direction);

		    #build the command
		    if (grep ("hpn", $source)) {
			$binary = "$conf{root}/$source/bin/hpnssh";
		    } else {
			$binary = "$conf{root}/$source/bin/ssh";
		    }
		    my $command = "dd if=/dev/zero bs=1M count=$size | $binary $conf{verbose} $conf{protocol} $extended $modified_cipher -p $port $conf{target} 'cat > /dev/null'";

		    #run the command and capture output
		    runCommand($command, $source, $dest, $cipher, "outbound", $delay);
		    if ($bidirectional == 1) {
			$command = "$binary $conf{verbose} $conf{protocol} $extended $modified_cipher -p $port $conf{target} 'dd if=/dev/zero bs=1M count=$size' > /dev/null";
			runCommand($command, $source, $dest, $cipher, "inbound", $delay);
		    }
		}
	    }
	}
    }
}

sub getSize {
    my $size = shift;
    my $source = shift;
    my $dest = shift;
    my $delay = shift;
    my $direction = shift;

    #if hpnssh is receiving the data then return the default size
    if (grep ("i/hpn/", $dest) && grep ("i/outbound", $direction)) {
	return $size;
    }
    if (grep ("i/hpn/", $source) && grep ("i/inbound", $direction)) {
	return $size;
    }

    # we are assuming all other receivers are stock
    # if size is 30000. Which has been a default for ages.
    # then the returned size are 30000, 10000, 5000, 1000 for
    # 0ms, 50ms, 100ms, and 150ms respectively. Which is what we
    # have been using for ages as well.
    if ($delay < 50) {
	return $size;
    }
    if ($delay < 100) {
	return int($size/3);
    }
    if ($delay < 150) {
	return int($size/6);
    }
    return int($size/30);
}

sub runCommand {
    my $command = shift;
    my $source = shift;
    my $dest = shift;
    my $cipher = shift;
    my $direction = shift;
    my $delay = shift;
    my @months = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );
    my @days = qw(Sun Mon Tue Wed Thu Fri Sat Sun);
    $year += 1900;
    my $dataline;

    if (grep ("i/out/", $direction)) {
	$pointer = "--->";
    } else {
	$pointer = "<---";
    }

    open (SFH, ">>", $config{outfile}) or die
	"Cannot open $config{outfile}: $!";

    print SFH "$config{host} $pointer $config{target}\n";
    print SFH "$cipher\n";

    for (my $j = 0; $j < $config{runs}; $j++) {
	#print the command and time for each run
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime();
	$date_string = sprintf("$days[$wday] $months[$mon] %02d $year %02d:%02d:%02d\n", $mday, $hour, $min, $sec);
	print SFH $date_string;
	print SFH "$command\n";
	qprint($date_string);
	qprint("$command\n");

	# Filehandles for capturing output
	my $stderr = gensym;  # Create a symbol for STDERR
	my $pid = open3(my $stdin, my $stdout, $stderr, $command);
	# Read STDOUT
	my $output = do { local $/; <$stdout> };

	# Read STDERR This has the data we want from dd
	my $error = do { local $/; <$stderr> };

	# print the debug logs if required
	if ($config{verbose} > 0) {
	    print SFH "Output: $output\n";
	    print SFH "Error : $error\n";
	}

	# we need this in case we are doing verbose output
	# on hpn-ssh.
	my @lines = split "\n", $error;
	foreach $line (@lines) {
	    if (grep /copied/, $line) {
		$dataline = $line;
		break;
	    }
	}

	# the last 24 chars should get all the data we need
	# note, we only want the last 2 commas from the dd command
	# I'm sure there is more clever way to do this.
      	my $results = substr $dataline, -24;
	(my $trash, my $time, my $speed) = split ",", $results;

	($time, $unit) = split " ", $time;
	($speed, $unit) = split " ", $speed;

	#convert the speed into Mbits
	if (grep /G/, $unit) {
	    $speed = $speed * 8000;
	} else {
	    $speed = $speed * 8;
	}

	push @{$data{$direction}{$delay}{$source}{$dest}{$cipher}{tput}}, $speed;
	push @{$data{$direction}{$delay}{$source}{$dest}{$cipher}{time}}, $time;
	qprint("Speed is $speed in $time s with $cipher\n");
	print SFH "Run $j: $direction $time $speed\n";
	# Wait for the command to finish
	waitpid($pid, 0);
    }
    if ($periodic) {
	computeStats();
    }
    close(SFH);
    #parse the output for the bit we want
}

# this *should* be setting the delay via qdisc
sub setDelay {
    my $delay = shift;
    $delay .= "ms";
    qprint("sudo tc qdisc del dev $config{interface} root\n");
    qprint("sudo tc qdisc add dev $config{interface} root netem delay $delay\n");
    print qx/sudo tc qdisc del dev $config{interface} root/;
    print qx/sudo tc qdisc add dev $config{interface} root netem delay $delay/;
}


# take the incoming cipher string and expand it to the
# switch required by ssh.
sub setCipher {
    $cipher = shift;
    $release = shift;
    #only use none mac with hpnssh
    if (grep ("i/nonemac/", $cipher) && grep ("hpn", $release)) {
	return "-oNoneSwitch=yes -oNoneEnabled=yes -oNoneMacEnabled=yes";
    }
    #only use none cipher with hpnssh
    if (grep ("i/none/", $cipher) && grep ("hpn", $release)) {
	return "-oNoneSwitch=yes -oNoneEnabled=yes";
    }
    # if they are using OpenSSH then mae sure the cc20 cipher
    # is their version and not ours
    if (grep ("chacha", $cipher) && ! grep ("hpn", $release)) {
	return "-cchacha20-poly1305@openssh.com";
    }
    return "-c$cipher";
}

#take the data we collected in %data hash and
# get min, max, mean, and stddev. We use information from
# %data and %config for this
# order in data is
# direction ->  delay -> source -> dest -> cipher -> tput
sub computeStats {
    my @out_results;
    my @in_results;

    open (SFH, ">>", $config{outfile}) or die
	"Cannot open $config{outfile}: $!";

    # start with outbound traffic
    foreach my $delay (sort { $a <=> $b } keys %{$data{outbound}}) {
	foreach my $source (sort keys %{$data{outbound}{$delay}}) {
	    foreach my $dest (sort keys %{$data{outbound}{$delay}{$source}}) {
		foreach my $cipher (sort keys %{$data{outbound}{$delay}{$source}{$dest}}) {
		    my $piddle = pdl $data{outbound}{$delay}{$source}{$dest}{$cipher}{tput};
		    ($mean,$prms,$median,$min,$max,$adev,$rms) = statsover $piddle;
		    my $line = sprintf("%-30s\t%-15s\t%-15s\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\tOutbound\t%d\n", $cipher,$source,$dest,$mean,$median,$min,$max,$adev,$delay);
		    push (@out_results, $line);

		}
	    }
	}
    }

    my $count = $#out_results;

    @out_results = sort { $a->[2] cmp $b->[2] } @out_results;
    #print the header
    print SFH "Outbound: From src to dest\n";
    print SFH "cipher,\t\t\t\tsrc,\t\tdst,\t\tmean,\tmedian,\tmin,\tmax,\tadev,\tdirection\trtt\n";
    qprint("Outbound: From src to dest\n");
    qprint("cipher,\t\t\t\tsrc,\t\tdst,\t\tmean,\tmedian,\tmin,\tmax,\tadev,\tdirection\trtt\n");

    for (my $i = 0;$i <= $count; $i++) {
	print SFH $out_results[$i];
	qprint($out_results[$i]);
    }
    print SFH "\n\n";
    qprint("\n\n");

    foreach my $delay (sort { $a <=> $b } keys %{$data{inbound}}) {
	foreach my $source (sort keys %{$data{inbound}{$delay}}) {
	    foreach my $dest (sort keys %{$data{inbound}{$delay}{$source}}) {
		foreach my $cipher (sort keys %{$data{inbound}{$delay}{$source}{$dest}}) {
		    my $piddle = pdl $data{inbound}{$delay}{$source}{$dest}{$cipher}{tput};
		    ($mean,$prms,$median,$min,$max,$adev,$rms) = statsover $piddle;
		    my $line = sprintf("%-30s\t%-15s\t%-15s\t%.2f\t%.2f\t%.2f\t%.2f\t%.2f\tOutbound\t%d\n", $cipher,$source,$dest,$mean,$median,$min,$max,$adev,$delay);
		    push (@in_results, $line);
		}
	    }
	}
    }

    $count = $#in_results;

    #print the header
    print SFH "Inbound: To src from dst\n";
    print SFH "cipher,\t\t\t\tsrc,\t\tdst,\t\tmean,\tmedian,\tmin,\tmax,\tadev,\tdirection\trtt\n";
    qprint("Inbound: To src from dst\n");
    qprint("cipher,\t\t\t\tsrc,\t\tdst,\t\tmean,\tmedian,\tmin,\tmax,\tadev,\tdirection\trtt\n");

    for (my $i = 0;$i <= $count; $i++) {
	qprint($in_results[$i]);
	print SFH $in_results[$i];
    }
    close (SFH);
}

# only print to terminal if quiet is not enabled
sub qprint {
    $message = shift;
    if (!$quiet) {
	print $message;
    }
}

#main

my $conf_file = "";

#this is a global
our %config = {};
our %data = {};

GetOptions("config=s" => \$conf_file,
           "outfile=s" => \$outfile,
           "periodic!" => \$periodic,
	   "extended=s" => \$extended,
           "help!" => \$help,
           "quiet!" => \$quiet);

if ((!$conf_file) or ($help)) {
    print ("
Usage: hpnssh-test-harness.pl
       --config=path/to/config/file REQUIRED
       --outfile=/path/to/optional/outputfile
	         This will override the output file
                 in the config.
       --periodic Print updated stats after each set
                 of runs.
       --extended=\"\"
                 Additional options for ssh.
 		 eg -oMPTCP=yes
       --quiet no printed output at all.
       --help print this.
");
    exit();
}

readConfig($conf_file);

runTests(0);
if ($config{bidirectional} > 0) {
    qprint("Running BI\n");
    runTests(1);
}

computeStats();

qprint("Ran tests\n");
