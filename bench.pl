#!/usr/bin/perl -w

=pod

=head1 NAME

bench.pl - Benchmark zlib implementations

=head1 SYNOPSIS

bench.pl [options]

 Options:
  --compress-iters=...   Number of times each file is compressed in one
                         benchmark run
  --compress-levels=...  Comma-separated list of compression levels to use
  --decompress-iters=... Number of times each file is compressed in one
                         benchmark run
  --help                 Print a help message
  --output-file=...      File (- for stdout) where results are printed to
  --output-format=...    Format to output results in (pretty, json)
  --read-json=...        Don't run benchmarks, but read results from this file
  --recompile            If passed, recompile all zlib versions before test
  --runs=...             Number of runs for each benchmark
  --quiet                Don't print progress reports to STDERR

=cut

use strict;

use BSD::Resource qw(times);
use Fatal qw(open);
use File::Slurp;
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
my $compress_iters = 10;
my $decompress_iters = 50;

# If true, recompile all the zlib versions before running benchmark
my $recompile = 0;

# pprint or json
my $output_format = "pretty";

# If true, don't print progress info to STDERR
my $quiet = 0;

sub trace {
    local $| = 1;
    print STDERR @_;
}

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
            trace "Checking out $version->{id}\n";
            checkout $version->{id}, $version->{repository}, $version->{commit_or_branch};
            trace "Compiling $version->{id}\n";
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

    my $res = benchmark_command "$zlib_dir/minigzip64 -d < $input > /dev/null", $iters;
    delete $res->{size};

    return $res;
}

sub benchmark_all {
    my %results = ();

    # Compression benchmarks
    for my $level (@compress_levels) {
        for my $input (glob "corpus/[a-z]*") {
            $input =~ m{.*/(.*)} or next;
            my $id = "compress $1 -$level (x $compress_iters)";
            trace "Testing '$id' ";

            $results{$id}{input}{size} = (-s $input);

            for (1..$runs) {
                for my $version (@versions) {
                    trace ".";

                    # Warm up
                    benchmark_compress $version->{dir}, $input, $level, 1;
                    my $result = benchmark_compress $version->{dir}, $input, $level, $compress_iters;
                    push @{$results{$id}{output}{"$version->{id}"}}, $result;
                }
            }

            trace "\n";
        }
    }

    # Decompression benchmarks. 

    # First create compressed files.
    my %compressed = ();
    for my $input (glob "corpus/[a-z]*") {
        my ($fh) = File::Temp->new();
        $compressed{$input}{fh} = $fh;
        $compressed{$input}{tmpfile} = $fh->filename;
        print $fh qx"$versions[0]{dir}/minigzip64 < $input";
        close $fh;
    }

    for my $input (glob "corpus/[a-z]*") {
        $input =~ m{.*/(.*)} or next;
        my $id = "decompress $1 (x $decompress_iters)";
        trace "Testing '$id' ";

        for (1..$runs) {
            for my $version (@versions) {
                trace ".";

                # Warm up
                benchmark_decompress $version->{dir}, $compressed{$input}{tmpfile}, 1;
                my $result = benchmark_decompress $version->{dir}, $compressed{$input}{tmpfile}, $decompress_iters;
                push @{$results{$id}{output}{"$version->{id}"}}, $result;
            }
        }

        trace "\n";
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
        versions => [
            map {
                { id => $_->{id},
                  commit => qx(cd $_->{dir} && git rev-parse HEAD)
                }
            } @versions ],
        results => \%results
    }
}

sub pprint {
    my ($output_file, $input) = @_;
    my @versions = @{$input->{versions}};
    my %results = %{$input->{results}};

    local *STDOUT = $output_file;

    printf "%20s ", '';        
    for my $version (@versions) {
        printf "%-22s ", $version->{id};
    }

    for my $key (sort keys %results) {
        my %benchmark = %{$results{$key}};
        printf "\n%s", $key;

        if ($benchmark{input}{size}) {
            printf "\n%20s ", "Compression ratio:";
            for my $version (@versions) {
                my $id = $version->{id};
                my $output_size = $benchmark{output}{$id}{output_size}{mean};
                my $input_size = $benchmark{input}{size};
                printf("%5.2f %17s",
                       $output_size / $input_size,
                       '');
            }
        }

        printf "\n%20s ", "Execution time [s]:";
        for my $version (@versions) {
            my $id = $version->{id};
            my $time = $benchmark{output}{$id}{time}{mean};
            my $error = $benchmark{output}{$id}{time}{error};
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
    my $output_file;
    my $read_json = '';

    Getopt::Long::Configure('auto_help');
    if (!GetOptions(
             "compress-levels=s" => sub {
                 @compress_levels = split /,/, $_[1];
                 for (@compress_levels) {
                     die "Invalid compression level $_\n" if /\D/;
                 }
             },
             "output-file=s" => sub {
                 if ($_[1] ne '-') {
                     open $output_file, ">", $_[1];
                 }
             },
             "output-format=s" => \$output_format,
             "read-json=s" => \$read_json,
             "recompile" => \$recompile,
             "compress-iters=i" => \$compress_iters,
             "decompress-iters=i" => \$decompress_iters,
             "runs=i" => \$runs,
             "quiet" => \$quiet,
        )) {
        exit(1);
    }

    die "--output-format should be 'pretty' or 'json'" if $output_format !~ /^(pretty)|(json)$/;

    $output_file //= *STDOUT;
    binmode($output_file, ":utf8");

    my $results;

    if ($read_json) {
        my $data = read_file $read_json;
        $results = decode_json $data;
    } else {
        init;
        fetch_and_compile_all;
        $results = benchmark_all;
    }

    if ($output_format eq 'pretty') {
        pprint $output_file, $results;
    } else {
        print $output_file encode_json $results;
    }
}

main;
