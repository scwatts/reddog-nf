#!/usr/bin/env python3
# TODO: check this is the correct process
# TODO: report stats?


import argparse
import pathlib


def get_arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument('--allele_fp', required=True, type=pathlib.Path,
            help='Input allele matrix filepath')
    args = parser.parse_args()
    if not args.allele_fp.exists():
        parser.error(f'Input file {args.allele_fp} does not exist')
    return args


def main():
    # Get command line arguments
    args = get_arguments()

    # Filter at 95% conservation
    with args.allele_fp.open('r') as fh:
        line_token_gen = (line.rstrip().split('\t') for line in fh)
        # Get and print header
        header_tokens = next(line_token_gen)
        print(*header_tokens, sep='\t')
        # Process alleles
        isolate_count = len(header_tokens) - 2
        for position, allele_ref, *allele_isolates in line_token_gen:
            # Remove invariant SNPs
            alleles_unique = {allele for allele in allele_isolates if allele != '-'}
            alleles_unique.add(allele_ref)
            if len(alleles_unique) == 1:
                continue
            # Remove SNPs with fewer than 95% known alleles
            alleles_known_pct = (1 - allele_isolates.count('-') / isolate_count) * 100
            if alleles_known_pct < 95:
                continue
            # Print passing alleles
            print(position, allele_ref, *allele_isolates, sep='\t')


if __name__ == '__main__':
    main()
