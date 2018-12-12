version 1.0

import "tasks/common.wdl" as common
import "tasks/htseq.wdl" as htseq
import "tasks/mergecounts.wdl" as mergeCounts
import "tasks/stringtie.wdl" as stringtie_task

workflow MultiBamExpressionQuantification {
    input {
        Array[Pair[String,IndexedBamFile]]+ bams #(sample, (bam, index))
        String outputDir
        String strandedness
        File? referenceGtfFile # Not providing the reference gtf will have stringtie do an unguided assembly
    }

    String stringtieDir = outputDir + "/stringtie/"
    String htSeqDir = outputDir + "/fragments_per_gene/" 

    # call counters per sample
    scatter (sampleBam in bams) {
        IndexedBamFile bamFile = sampleBam.right
        String sampleId = sampleBam.left

        call stringtie_task.Stringtie as stringtie {
            input:
                bamFile = bamFile,
                assembledTranscriptsFile = stringtieDir + sampleId + ".gtf",
                geneAbundanceFile = stringtieDir + sampleId + ".abundance",
                firstStranded = if strandedness == "RF" then true else false,
                secondStranded = if strandedness == "FR" then true else false,
                referenceGtf = referenceGtfFile
        }

        call FetchCounts as fetchCountsStringtieTPM {
            input:
                abundanceFile = select_first([stringtie.geneAbundance]),
                outputFile = stringtieDir + "/TPM/" + sampleId + ".TPM",
                column = 9
        }

        call FetchCounts as fetchCountsStringtieFPKM {
            input:
                abundanceFile = select_first([stringtie.geneAbundance]),
                outputFile = stringtieDir + "/FPKM/" + sampleId + ".FPKM",
                column = 8
        }

        Map[String, String] HTSeqStrandOptions = {"FR": "yes", "RF": "reverse", "None": "no"}
        call htseq.HTSeqCount as htSeqCount {
            input:
                inputBams = [bamFile.file],
                inputBamsIndex = [bamFile.index],
                outputTable = htSeqDir + sampleId + ".fragments_per_gene",
                stranded = HTSeqStrandOptions[strandedness],
                # Use the reference gtf if provided. Otherwise use the gtf file generated by stringtie
                gtfFile = select_first([referenceGtfFile, stringtie.assembledTranscripts])
        }
    }

    # Merge count tables into one multisample count table per count type
    call mergeCounts.MergeCounts as mergedStringtieTPMs {
        input:
            inputFiles = fetchCountsStringtieTPM.counts,
            outputFile = stringtieDir + "/TPM/all_samples.TPM",
            featureColumn = 1,
            valueColumn = 2,
            inputHasHeader = true
    }

    call mergeCounts.MergeCounts as mergedStringtieFPKMs {
        input:
            inputFiles = fetchCountsStringtieFPKM.counts,
            outputFile = stringtieDir + "/FPKM/all_samples.FPKM",
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

    output {
        File fragmentsPerGeneTable = mergedHTSeqFragmentsPerGenes.mergedCounts
        File FPKMTable = mergedStringtieFPKMs.mergedCounts
        File TPMTable = mergedStringtieTPMs.mergedCounts
        Array[Pair[String, File]] sampleGtfFiles = zip(sampleId, stringtie.assembledTranscripts)
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