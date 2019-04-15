version 1.0

import "tasks/collect-columns.wdl" as collectColumns
import "tasks/common.wdl" as common
import "tasks/htseq.wdl" as htseq
import "tasks/stringtie.wdl" as stringtie_task

workflow MultiBamExpressionQuantification {
    input {
        Array[Pair[String,IndexedBamFile]]+ bams #(sample, (bam, index))
        String outputDir
        String strandedness
        File? referenceGtfFile # Not providing the reference gtf will have stringtie do an unguided assembly
        Boolean detectNovelTranscripts = if defined(referenceGtfFile) then false else true
        Array[String]+? additionalAttributes

        Map[String, String] dockerTags = {
            "htseq": "0.9.1--py36h7eb728f_2",
            "stringtie": "1.3.4--py35_0",
            "collect-columns":"0.1.1--py_0"
        }
    }

    String stringtieDir = outputDir + "/stringtie/"
    String stringtieAssemblyDir = outputDir + "/stringtie/assembly/"
    String htSeqDir = outputDir + "/fragments_per_gene/"

    if (detectNovelTranscripts) {
        # assembly per sample
        scatter (sampleBam in bams) {
            IndexedBamFile bamFileAssembly = sampleBam.right
            String sampleIdAssembly = sampleBam.left

            call stringtie_task.Stringtie as stringtieAssembly {
                input:
                    bamFile = bamFileAssembly,
                    assembledTranscriptsFile = stringtieAssemblyDir + sampleIdAssembly + ".gtf",
                    firstStranded = if strandedness == "RF" then true else false,
                    secondStranded = if strandedness == "FR" then true else false,
                    referenceGtf = referenceGtfFile,
                    skipNovelTranscripts = false,
                    dockerTag = dockerTags["stringtie"]
            }
        }

        # merge assemblies
        call stringtie_task.Merge as mergeStringtieGtf {
            input:
                gtfFiles = stringtieAssembly.assembledTranscripts,
                outputGtfPath = stringtieAssemblyDir + "/merged.gtf",
                guideGtf = referenceGtfFile,
                dockerTag = dockerTags["stringtie"]
        }
    }

    # call counters per sample, using merged assembly if generated
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
                referenceGtf = select_first([mergeStringtieGtf.mergedGtfFile, referenceGtfFile]),
                skipNovelTranscripts = true,
                dockerTag = dockerTags["stringtie"]
        }

        Map[String, String] HTSeqStrandOptions = {"FR": "yes", "RF": "reverse", "None": "no"}
        call htseq.HTSeqCount as htSeqCount {
            input:
                inputBams = [bamFile.file],
                inputBamsIndex = [bamFile.index],
                outputTable = htSeqDir + sampleId + ".fragments_per_gene",
                stranded = HTSeqStrandOptions[strandedness],
                # Use the reference gtf if provided. Otherwise use the gtf file generated by stringtie
                gtfFile = select_first([mergeStringtieGtf.mergedGtfFile, referenceGtfFile]),
                dockerTag = dockerTags["htseq"]
        }
    }

    # Merge count tables into one multisample count table per count type
    call collectColumns.CollectColumns as mergedStringtieTPMs {
        input:
            inputTables = select_all(stringtie.geneAbundance),
            outputPath = stringtieDir + "/all_samples.TPM",
            valueColumn = 9,
            sampleNames = sampleId,
            header = true,
            additionalAttributes = additionalAttributes,
            referenceGtf = select_first([mergeStringtieGtf.mergedGtfFile, referenceGtfFile]),
            dockerTag = dockerTags["collect-columns"]
    }

    call collectColumns.CollectColumns as mergedStringtieFPKMs {
        input:
            inputTables = select_all(stringtie.geneAbundance),
            outputPath = stringtieDir + "/all_samples.FPKM",
            valueColumn = 8,
            sampleNames = sampleId,
            header = true,
            additionalAttributes = additionalAttributes,
            referenceGtf = select_first([mergeStringtieGtf.mergedGtfFile, referenceGtfFile]),
            dockerTag = dockerTags["collect-columns"]
    }

    call collectColumns.CollectColumns as mergedHTSeqFragmentsPerGenes {
        input:
            inputTables = select_all(stringtie.geneAbundance),
            outputPath = htSeqDir + "/all_samples.fragments_per_gene",
            sampleNames = sampleId,
            additionalAttributes = additionalAttributes,
            referenceGtf = select_first([mergeStringtieGtf.mergedGtfFile, referenceGtfFile]),
            dockerTag = dockerTags["collect-columns"]
    }

    output {
        File fragmentsPerGeneTable = mergedHTSeqFragmentsPerGenes.outputTable
        File FPKMTable = mergedStringtieFPKMs.outputTable
        File TPMTable = mergedStringtieTPMs.outputTable

        Array[Pair[String, File]] sampleGtfFiles = if detectNovelTranscripts
            then zip(select_first([sampleIdAssembly]),
                select_first([stringtieAssembly.assembledTranscripts]))
            else []
        File? mergedGtfFile = mergeStringtieGtf.mergedGtfFile
    }
}