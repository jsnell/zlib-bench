#!/usr/bin/perl -w

=pod

=head1 NAME

bench.pl - Benchmark zlib implementations

=head1 SYNOPSIS

bench.pl [options]

 Options:
  --help                Print a help message
  --compress-levels=... Comma-separated list of compression levels to use
  --output-format=...   Format to output results in (pretty, json)
  --recompile           If passed, recompile all zlib versions before test
  --runs=...            Number of runs for each benchmark
  --run-size=...        Number of times each file is compressed /
                        decompressed in one benchmark run

=cut

use strict;

use BSD::Resource qw(times);
use File::Temp qw(tempfile);
use Getopt::Long;
use JSON;
use List::Util qw(sum);
use Pod::Usage;
use Statistics::Descriptive;

# Versions to test
my @versions = (
    { id => 'baseline', repository => 'https://github.com/madler/zlib.git', commit_or_branch => '50893291621658f355bc5b4d450a8d06a563053d' },
    { id => 'cloudflare', repository => 'https://github.com/cloudflare/zlib.git', commit_or_branch => '8fe233dbf33766ed73940baebdb901de8257c59c' },
    { id => 'intel', repository => 'https://github.com/jtkukunas/zlib.git', commit_or_branch => 'e176b3c23ace88d5ded5b8f8371bbab6d7b02ba8'},
);

# Compression levels to benchmark
my @compress_levels = qw(1 3 5 9);

# Number of iterations of each benchmark to run (in addition to a single
# warmup run).
my $runs = 5;

# Number of compressions / decompressions to do in each run
my $run_size = 10;

# If true, recompile all the zlib versions before running benchmark
my $recompile = 0;

# pprint or json
my $output_format = "pretty";

sub checkout {
    my ($id, $repository, $commit_or_branch) = @_;
    my $dir = "zlib.$id";

    if (-d $dir) {
        if (system "cd $dir && git reset --hard $commit_or_branch") {
            die "'git checkout' of '$commit_or_branch' in $dir failed\n";
        }
    } else {
        if (system "git clone $repository $dir") {
            die "'git clone' of $id failed\n";
        }
        checkout(@_);
    }

    $dir;
}

sub compile {
    my ($dir) = @_;
    system "cd $dir && ./configure && make";
}

sub init {
    for my $version (@versions) {
        $version->{dir} = "zlib.$version->{id}";
    }
}

sub fetch_and_compile_all {
    for my $version (@versions) {
        if ($recompile or
            !-f "$version->{dir}/minigzip64") {
            checkout $version->{id}, $version->{repository}, $version->{commit_or_branch};
            compile $version->{dir};
        }
    }
}

sub benchmark_command {
    my ($command, $iters) = @_;

    my (@start_times) = times;

    my $size;
    for (1..$iters) {
        $size = length qx"$command";
    }

    my (@end_times) = times;

    { output_size => $size,
      time => sum(@end_times[2,3]) - sum(@start_times[2,3])}
}

sub benchmark_compress {
    my ($zlib_dir, $input, $level, $iters) = @_;

    benchmark_command "$zlib_dir/minigzip64 -$level < $input", $iters;
}

sub benchmark_decompress {
    my ($zlib_dir, $input, $iters) = @_;

    my $res = benchmark_command "$zlib_dir/minigzip64 < $input", $iters;
    delete $res->{size};

    return $res;
}

sub benchmark_all {
    my %results = ();

    # Compression benchmarks
    for my $version (@versions) {
        for my $level (@compress_levels) {
            for my $input (glob "corpus/[a-z]*") {
                $input =~ m{.*/(.*)} or next;
                my $id = "compress $1 -$level";

                # Warm up
                benchmark_compress $version->{dir}, $input, $level, 1;

                $results{$id}{input}{size} = (-s $input);

                for (1..$runs) {
                    my $result = benchmark_compress $version->{dir}, $input, $level, $run_size;
                    push @{$results{$id}{output}{"$version->{id}"}}, $result;
                }
            }
        }
    }

    # Decompression benchmarks. 

    # First create compressed files.
    my %compressed = ();
    for my $input (glob "corpus/[a-z]*") {
        my ($fh, $filename) = tempfile();
        $compressed{$input}{tmpfile} = $filename;
        print $fh qx"$versions[0]{dir}/minigzip64 < $input";
        close $fh;
    }

    for my $version (@versions) {
        for my $input (glob "corpus/[a-z]*") {
            $input =~ m{.*/(.*)} or next;
            my $id = "decompress $1";

            # Warm up
            benchmark_decompress $version->{dir}, $compressed{$input}{tmpfile}, 1;

            for (1..$runs) {
                my $result = benchmark_decompress $version->{dir}, $compressed{$input}{tmpfile}, $run_size;
                push @{$results{$id}{output}{"$version->{id}"}}, $result;
            }
        }
    }

    for my $input_results (values %results) {
        for my $version_results (values %{$input_results->{output}}) {
            my $processed = {};
            for my $field (qw(output_size time)) {
                my $stat = Statistics::Descriptive::Full->new();
                for my $result (@{$version_results}) {
                    $stat->add_data($result->{$field});
                }
                $processed->{$field} = {
                    mean => $stat->mean(),
                    error => $stat->standard_deviation() / sqrt($stat->count()),
                };
            }

            $version_results = $processed;
        }
    }

    return {
        versions => [ map { $_->{id} } @versions ],
        results => \%results
    }
}

sub pprint {
    my ($input) = @_;
    my @versions = @{$input->{versions}};
    my %results = %{$input->{results}};

    printf "%20s ", '';        
    for my $version (@versions) {
        printf "%-22s ", $version;        
    }

    for my $key (sort keys %results) {
        my %benchmark = %{$results{$key}};
        printf "\n%s", $key;

        if ($benchmark{input}{size}) {
            printf "\n%20s ", "Compression ratio:";
            for my $version (@versions) {
                my $output_size = $benchmark{output}{$version}{output_size}{mean};
                my $input_size = $benchmark{input}{size};
                printf("%5.2f %17s",
                       $output_size / $input_size,
                       '');
            }
        }

        printf "\n%20s ", "Execution time [s]:";
        for my $version (@versions) {
            my $time = $benchmark{output}{$version}{time}{mean};
            my $error = $benchmark{output}{$version}{time}{error};
            my $basetime = $benchmark{output}{'baseline'}{time}{mean};
            printf("%5.2f \x{00b1} %4.2f (%6.2f%%) ",
                   $time,
                   $error,
                   $time / $basetime * 100, 
                   '');
        }
    }

    printf "\n";
}

sub main {
    my $help = 0;

    Getopt::Long::Configure('auto_help');
    if (!GetOptions(
             "compress-levels=s" => sub {
                 @compress_levels = split /,/, $_[1];
                 for (@compress_levels) {
                     die "Invalid compression level $_\n" if /\D/;
                 }
             },
             "output-format=s" => \$output_format,
             "recompile" => \$recompile,
             "run-size=i" => \$run_size,
             "runs=i"  => \$runs,
        )) {
        exit(1);
    }

    die "--output-format should be 'pretty' or 'json'" if $output_format !~ /^(pretty)|(json)$/;

    binmode(STDOUT, ":utf8");

    init;
    fetch_and_compile_all;
    my $results = benchmark_all;

    if ($output_format eq 'pretty') {
        pprint $results;
    } else {
        print encode_json $results;
    }
}

main;
