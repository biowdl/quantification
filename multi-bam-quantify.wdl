import "tasks/mergecounts.wdl" as mergeCounts
import "tasks/stringtie.wdl" as stringtie_task
import "tasks/biopet.wdl" as biopet
import "tasks/htseq.wdl" as htseq

workflow MultiBamExpressionQuantification {
    Array[Pair[String,Pair[File,File]]]+ bams #(sample, (bam, index))
    #Map[String, Pair[File, File]] bams
    String outputDir
    String strandedness
    File refGtf
    File refRefflat

    # call counters per sample
    scatter (sampleBam in bams) {
        Pair[File,File] bamFile = sampleBam.right

        call stringtie_task.Stringtie as stringtie {
            input:
                alignedReads = bamFile.left,
                assembledTranscriptsFile = outputDir + "/stringtie/" + sampleBam.left + ".gff",
                geneAbundanceFile = outputDir + "/stringtie/" + sampleBam.left + ".abundance",
                firstStranded = if strandedness == "FR" then true else false,
                secondStranded = if strandedness == "RF" then true else false,
                referenceGtf = refGtf
        }

        call FetchCounts as fetchCountsStringtieTPM {
            input:
                abundanceFile = select_first([stringtie.geneAbundance]),
                outputFile = outputDir + "/stringtie/TPM/" + sampleBam.left + ".TPM",
                column = 9
        }

        call FetchCounts as fetchCountsStringtieFPKM {
            input:
                abundanceFile = select_first([stringtie.geneAbundance]),
                outputFile = outputDir + "/stringtie/FPKM/" + sampleBam.left + ".FPKM",
                column = 8
        }

        Map[String, String] HTSeqStrandOptions = {"FR": "yes", "RF": "reverse", "None": "no"}
        call htseq.HTSeqCount as htSeqCount {
            input:
                alignmentFiles = bamFile.left,
                outputTable = outputDir + "/fragments_per_gene/" + sampleBam.left + ".fragments_per_gene",
                stranded = HTSeqStrandOptions[strandedness],
                gtfFile = refGtf
        }

        call biopet.BaseCounter as baseCounter {
            input:
                bam = bamFile.left,
                bamIndex = bamFile.right,
                outputDir = outputDir + "/BaseCounter/",
                prefix = sampleBam.left,
                refFlat = refRefflat
        }
    }

    # Merge count tables into one multisample count table per count type
    call mergeCounts.MergeCounts as mergedStringtieTPMs {
        input:
            inputFiles = fetchCountsStringtieTPM.counts,
            outputFile = outputDir + "/stringtie/TPM/all_samples.TPM",
            featureColumn = 1,
            valueColumn = 2,
            inputHasHeader = true
    }

    call mergeCounts.MergeCounts as mergedStringtieFPKMs {
        input:
            inputFiles = fetchCountsStringtieFPKM.counts,
            outputFile = outputDir + "/stringtie/FPKM/all_samples.FPKM",
            featureColumn = 1,
            valueColumn = 2,
            inputHasHeader = true
    }

    call mergeCounts.MergeCounts as mergedHTSeqFragmentsPerGenes {
        input:
            inputFiles = htSeqCount.counts,
            outputFile = outputDir + "/fragments_per_gene/all_samples.fragments_per_gene",
            featureColumn = 1,
            valueColumn = 2,
            inputHasHeader = false
    }

    call mergeCounts.MergeCounts as mergedBaseCountsPerGene {
        input:
            inputFiles = if strandedness == "FR" then baseCounter.geneSense else (
                if strandedness == "RF" then baseCounter.geneAntisense else baseCounter.gene),
            outputFile = outputDir + "/BaseCounter/all_samples.base.gene.counts",
            featureColumn = 1,
            valueColumn = 2,
            inputHasHeader = false
    }

    output {
        File baseCountsPerGeneTable = mergedBaseCountsPerGene.mergedCounts
        File fragmentsPerGeneTable = mergedHTSeqFragmentsPerGenes.mergedCounts
        File FPKMTable = mergedStringtieFPKMs.mergedCounts
        File TPMTable = mergedStringtieTPMs.mergedCounts
    }
}


task FetchCounts {
    File abundanceFile
    String outputFile
    Int column

    command <<<
        mkdir -p ${sub(outputFile, basename(outputFile) + "$", "")}
        awk -F "\t" '{print $1 "\t" $${column}}' ${abundanceFile} > ${outputFile}
    >>>

    output {
        File counts = outputFile
    }
}