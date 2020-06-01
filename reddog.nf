#!/usr/bin/env nextflow
// Enable DSL2
nextflow.preview.dsl=2


// NOTE: imports separated for readability
// Alignment and variant calling processes
include align_reads_pe from './src/processes/alignment.nf'
include call_snps from './src/processes/variant_calling.nf'

// Mapping stats processes
include calculate_gene_coverage_depth from './src/processes/mapping_stats.nf'
include calculate_mapping_statistics from './src/processes/mapping_stats.nf'
include aggregate_mapping_statistics from './src/processes/mapping_stats.nf'

// Allele matrix processes
include create_allele_matrix from './src/processes/allele_matrix.nf'
include aggregate_allele_matrices from './src/processes/allele_matrix.nf'
include filter_allele_matrix from './src/processes/allele_matrix.nf'

// Merge processes
include merge_gene_depth from './src/processes/merge.nf'
include merge_gene_coverage from './src/processes/merge.nf'
include merge_allele_matrix from './src/processes/merge.nf'
include merge_mapping_stats from './src/processes/merge.nf'

// Other processes
include prepare_reference from './src/processes/misc.nf'
include subsample_reads from './src/processes/misc.nf'
include create_read_quality_reports from './src/processes/misc.nf'
include create_mpileups from './src/processes/misc.nf'
include aggregate_read_quality_reports from './src/processes/misc.nf'
include determine_coding_consequences from './src/processes/misc.nf'
include create_snp_alignment from './src/processes/misc.nf'
include infer_phylogeny from './src/processes/misc.nf'
include aggregate_snp_sites from './src/processes/misc.nf'

// Channel helper functions
include get_read_prefix_and_type from './src/channel_helpers.nf'
include collect_passing_isolate_replicons from './src/channel_helpers.nf'
include sort_allele_matrices from './src/channel_helpers.nf'
include filter_empty_allele_matrices from './src/channel_helpers.nf'
include get_replicon_id from './src/channel_helpers.nf'

// Utility functions
include print_splash from './src/utilities.nf'
include print_help from './src/utilities.nf'
include check_arguments from './src/utilities.nf'
include check_input_files from './src/utilities.nf'
include check_output_dir from './src/utilities.nf'
include check_host from './src/utilities.nf'
include check_boolean_option from './src/utilities.nf'


// Check configuration
print_splash()
check_arguments(params)
check_input_files(workflow, params)
check_output_dir(params)
check_host(workflow)


// Require optional stage variables to be boolean
// We must check and change values if needed. The global param variables are immutable so instead we declare new ones
run_read_subsample = check_boolean_option(params.subsample_reads, 'subsample_reads')
run_quality_assessment = check_boolean_option(params.quality_assessment, 'quality_assessment')
run_phylogeny = check_boolean_option(params.force_tree, 'force_tree')
merge_run = check_boolean_option(params.merge_run, 'merge_run')


// Check integer params
if (run_read_subsample & params.subsample_read_count.getClass() != java.lang.Integer) {
  if (! params.subsample_read_count.isInteger()) {
    exit 1, "error: subsample_read_count must be an integer, got {params.subsample_read_count}"
  }
}


// Get reads and seperate into pe and se channels based on prefix
reads = Channel.fromPath(params.reads).ifEmpty {
    exit 1, "error: did not find any read files value '${params.reads}'"
  }.map {
    get_read_prefix_and_type(it)
  }.branch {
    paired: it[0] == 'pe'
    single: it[0] == 'se'
}
reads_se = reads.single.map { it[1..-1] }.groupTuple()
reads_pe = reads.paired.map { it[1..-1] }.groupTuple()
// Check that we have the expected number of reads for each prefix in pe and se channels
reads_pe.map {
  if (it[1].size() != 2) {
    exit 1, "error: didn't get exactly two readsets prefixed with ${it[0]}:\n${it[1]}"
  }
}
reads_se.map {
  if (it[1].size() != 1) {
    exit 1, "error: didn't get exactly one readset prefixed with ${it[0]}:\n${it[1]}"
  }
}


// Additionally create channel which contains all read filepaths
reads_all_fps = reads_pe.map { it[1..-1] }.mix(reads_se.map { it[1..-1] }).flatten()


// Create file object for reference and check it exists
reference_fp = file(params.reference)
if (! reference_fp.exists()) {
  exit 1, "error: reference input '${reference_fp}' does not exist"
}


// TODO: check merge inputs exist and are complete
//       - no missing isolates
//       - reference is the same - size, genes, names, replicons
//       - configure is the same - thresholds, bowtie2 mapping params
// TODO: ensure collisions in filename space between new and previous datasets
if (merge_run) {
  if (params.previous_run_dir.isEmpty()) {
    exit 1, "error: a merge run requires previous_run_dir to be set"
  }
  merge_source_dir = file(params.previous_run_dir)
  if (! merge_source_dir.exists()) {
    exit 1, "error: directory for previous_run_dir (${params.previous_run_dir}) does not exist"
  }
  merge_source_fastqc = Channel.fromPath(merge_source_dir / 'fastqc/individual_reports/*')
  merge_source_gene_depth = Channel.fromPath(merge_source_dir / '*gene_depth.tsv')
  merge_source_gene_coverage = Channel.fromPath(merge_source_dir / '*gene_coverage.tsv')
  merge_source_mapping_stats = Channel.fromPath(merge_source_dir / '*mapping_stats.tsv')
  merge_source_allele_matrices = Channel.fromPath(merge_source_dir / '*alleles.tsv')
}


// Run workflow - this unnamed workflow will be implicity executed
workflow {
  main:
    reference_data = prepare_reference(reference_fp)

    if (run_read_subsample) {
      reads_se = subsample_reads_se(reads_se)
      reads_pe = subsample_reads_pe(reads_pe)
    }

    if (run_quality_assessment) {
      ch_fastqc = create_read_quality_reports(reads_all_fps).output
    }

    align_data_se = align_reads_se(reads_se, reference_data.fasta, reference_data.bt2_index)
    align_data_pe = align_reads_pe(reads_pe, reference_data.fasta, reference_data.bt2_index)
    align_data = align_data_se.mix(align_data_pe)

    mpileup_data = create_mpileups(align_data.bams)

    bams_and_mpileups = align_data.bams.join(mpileup_data.output)
    snp_data = call_snps(bams_and_mpileups, reference_data.fasta, reference_data.samtools_index)

    bams_vcfs_stats_and_metrics = align_data.bams.join(snp_data.vcfs)
      .join(snp_data.coverage_depth)
      .join(align_data.metrics)
    stats_data = calculate_mapping_statistics(bams_vcfs_stats_and_metrics)

    stats_aggregated_data = aggregate_mapping_statistics(stats_data.collect(), reference_data.name)

    sites_data = aggregate_snp_sites(snp_data.sites.collect(), stats_aggregated_data.isolate_replicons)

    gene_coverage_depth = calculate_gene_coverage_depth(mpileup_data.output_noid.collect(), reference_fp)

    // Remove isolates that have no replicons that pass mapping criteria and then add SNP site file to each BAM
    // We perform this here so that we do not run jobs for isolates that have no passing replicons
    isolate_replicons_passing = collect_passing_isolate_replicons(stats_aggregated_data.isolate_replicons)
    bams_and_sites = align_data.bams.join(isolate_replicons_passing).combine(sites_data.output)
    matrix_data = create_allele_matrix(bams_and_sites, reference_data.fasta)

    replicon_allele_matrices = sort_allele_matrices(matrix_data.output)
    matrix_aggregate_data = aggregate_allele_matrices(replicon_allele_matrices, sites_data.output, reference_data.name)

    ch_allele_matrices = filter_empty_allele_matrices(matrix_aggregate_data.output)

    // Merge previous run data if requested
    if (merge_run) {
      // TODO: currently have three separate branches just for quality assessment, can we do better?
      if (run_quality_assessment) {
        // Symlink in previous FastQC reports
        fastqc_individual_output_dir = file(params.output_dir) / 'fastqc/individual_reports/'
        if (! fastqc_individual_output_dir.exists()) {
          fastqc_individual_output_dir.mkdirs()
        }
        merge_source_fastqc.map { filepath_src ->
          filepath_dst = fastqc_individual_output_dir / filepath_src.getName()
          if (! filepath_dst.exists()) {
            java.nio.file.Files.createSymbolicLink(filepath_dst, filepath_src)
          }
        }
        // Filter for zip files and add these to existing channel
        ch_fastqc = ch_fastqc.flatten().mix(merge_source_fastqc.filter { it.getName().endsWith('zip') })
      }

      // Merge gene stats tables
      merge_gene_depth(gene_coverage_depth.depth, merge_source_gene_depth, reference_data.name)
      merge_gene_coverage(gene_coverage_depth.coverage, merge_source_gene_coverage, reference_data.name)

      // Merge mapping stats
      // NOTE: reference_fp.simpleName is required as execution is immediate - reference_data may not be available
      merge_source_mapping_stats = get_replicon_id(merge_source_mapping_stats, '_mapping_stats.tsv', reference_fp.simpleName)
      mapping_stats = stats_aggregated_data.stats.map { [it.getName().minus('_mapping_stats.tsv'), it] }
      ch_mapping_stats_merge = mapping_stats.mix(merge_source_mapping_stats).groupTuple()
      merge_mapping_stats(ch_mapping_stats_merge, reference_data.name)

      // TODO: catch where an allele matrix is create for a replicon in one run but not another
      //       just skip merging for these tables and send straight to filter channel
      // Merge allele matrices and update channel
      merge_source_allele_matrices = get_replicon_id(merge_source_allele_matrices, '_alleles.tsv', reference_fp.simpleName)
      ch_allele_matrices_merge = ch_allele_matrices.mix(merge_source_allele_matrices).groupTuple()
      ch_allele_matrices = merge_allele_matrix(ch_allele_matrices_merge, reference_data.name)
    }

    if (run_quality_assessment) {
      aggregate_read_quality_reports(ch_fastqc.collect())
    }

    allele_matrices_core = filter_allele_matrix(ch_allele_matrices, reference_data.name)

    determine_coding_consequences(allele_matrices_core, reference_fp)

    // TODO: restore isolate_count logic - issues with channel->int in DSL2
    isolate_count = 500
    snp_alignment = create_snp_alignment(allele_matrices_core, reference_data.name)
    if (isolate_count <= 1000 | run_phylogeny) {
      infer_phylogeny(snp_alignment, reference_data.name)
    }
}
