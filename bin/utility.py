import statistics


def assign_ingroup_outgroup(records, stddev_mod):
    # Ratios for all passing isolates
    ratios = list()
    for record in records:
        if record.pass_fail != 'p':
            continue
        record.ratio = int(record.total_reads) / float(record.replicon_coverage) / 100
        ratios.append(record.ratio)
    # If we have sufficient entries, calculate ingroup/outgroup threshold
    if len(ratios) > 1:
        ratio_stddev = statistics.stdev(ratios)
        ratio_mean = statistics.mean(ratios)
        ratio_max = ratio_mean + ratio_stddev * stddev_mod
    # Apply groups
    for record in records:
        if not record.ratio:
            continue
        if len(ratios) <= 1:
            record.phylogeny_group = 'undetermined'
        elif record.ratio <= ratio_max:
            record.phylogeny_group = 'i'
        elif record.ratio > ratio_max:
            record.phylogeny_group = 'o'
    return records