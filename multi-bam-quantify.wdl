version 1.0

import "tasks/mergecounts.wdl" as mergeCounts
import "tasks/stringtie.wdl" as stringtie_task
import "tasks/biopet/biopet.wdl" as biopet
import "tasks/htseq.wdl" as htseq
import "tasks/common.wdl" as common

workflow MultiBamExpressionQuantification {
    input {
        Array[Pair[String,IndexedBamFile]]+ bams #(sample, (bam, index))
        #Map[String, Pair[File, File]] bams
        String outputDir
        String strandedness
        File gtfFile
        File refflatFile
    }
    
    String baseCounterDir = outputDir + "/BaseCounter/"
    String strintieDir = outputDir + "/stringtie/"
    String htSeqDir = outputDir + "/fragments_per_gene/" 

    # call counters per sample
    scatter (sampleBam in bams) {
        IndexedBamFile bamFile = sampleBam.right

        call stringtie_task.Stringtie as stringtie {
            input:
                bamFile = bamFile,
                assembledTranscriptsFile = strintieDir + sampleBam.left + ".gff",
                geneAbundanceFile = strintieDir + sampleBam.left + ".abundance",
                firstStranded = if strandedness == "FR" then true else false,
                secondStranded = if strandedness == "RF" then true else false,
                referenceGtf = gtfFile
        }

        call FetchCounts as fetchCountsStringtieTPM {
            input:
                abundanceFile = select_first([stringtie.geneAbundance]),
                outputFile = strintieDir + "/TPM/" + sampleBam.left + ".TPM",
                column = 9
        }

        call FetchCounts as fetchCountsStringtieFPKM {
            input:
                abundanceFile = select_first([stringtie.geneAbundance]),
                outputFile = strintieDir + "/FPKM/" + sampleBam.left + ".FPKM",
                column = 8
        }

        Map[String, String] HTSeqStrandOptions = {"FR": "yes", "RF": "reverse", "None": "no"}
        call htseq.HTSeqCount as htSeqCount {
            input:
                inputBams = [bamFile.file],
                inputBamsIndex = [bamFile.index],
                outputTable = htSeqDir + sampleBam.left + ".fragments_per_gene",
                stranded = HTSeqStrandOptions[strandedness],
                gtfFile = gtfFile
        }

        call biopet.BaseCounter as baseCounter {
            input:
                bam = bamFile,
                outputDir = baseCounterDir,
                prefix = sampleBam.left,
                refFlat = refflatFile
        }
    }

    # Merge count tables into one multisample count table per count type
    call mergeCounts.MergeCounts as mergedStringtieTPMs {
        input:
            inputFiles = fetchCountsStringtieTPM.counts,
            outputFile = strintieDir + "/TPM/all_samples.TPM",
            featureColumn = 1,
            valueColumn = 2,
            inputHasHeader = true
    }

    call mergeCounts.MergeCounts as mergedStringtieFPKMs {
        input:
            inputFiles = fetchCountsStringtieFPKM.counts,
            outputFile = strintieDir + "/FPKM/all_samples.FPKM",
            featureColumn = 1,
            valueColumn = 2,
            inputHasHeader = true
    }

    call mergeCounts.MergeCounts as mergedHTSeqFragmentsPerGenes {
        input:
            inputFiles = htSeqCount.counts,
            outputFile = htSeqDir + "/all_samples.fragments_per_gene",
            featureColumn = 1,
            valueColumn = 2,
            inputHasHeader = false
    }

    call mergeCounts.MergeCounts as mergedBaseCountsPerGene {
        input:
            inputFiles = if strandedness == "FR"
                then baseCounter.geneSense
                else (
                    if strandedness == "RF"
                        then baseCounter.geneAntisense
                        else baseCounter.gene
                ),
            outputFile = baseCounterDir + "/all_samples.base.gene.counts",
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
    input {
        File abundanceFile
        String outputFile
        Int column
    }

    command <<<
        mkdir -p ~{sub(outputFile, basename(outputFile) + "$", "")}
        awk -F "\t" '{print $1 "\t" $~{column}}' ~{abundanceFile} > ~{outputFile}
    >>>

    output {
        File counts = outputFile
    }
}