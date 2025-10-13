# hpnssh-perf-matrix-tests
Test HPN-SSH performance against a matrix of other versions. 

This is largely for internal use by the HPN-SSH development team. 
If you want to use it for yourself that's great but there won't be
huge amount of support for it. 

It's a pretty straightforward perl script that tests various
releases of HPN-SSH across a local network using netem delay to 
inject synthetic delay into the path. The test will iterate over
the version, the ciphers, the delays, and outbound vs inbound traffic. 
The results are then compiled to produce the min, max, mean, median,
and standard deviation over each set of runs per iteration. For example, 
if you have 15 runs of a specific iteration you will get the major stats
for those 15 runs. 

You will need the following perl modules installed to make use of this
Getopt::Long
Switch::Back
Data::Dumper
Socket::More::Interface
IPC::Open3
PDL

These tests can take a very long time. For example, lets say you are testing
hpn 18.8.0 against 18.7.0 and you are testing 5 ciphers and 4 delays both
inbound and outbound and rou are running each specific variation 15 times.
That's going to be a total 2400 test runs. If each run takes 1 minute
thats about 40 hours of testing. If you are logging into a remote server to
run these tests I *highly* suggest running it inside of screen in the event 
you lose your terminal session. 

