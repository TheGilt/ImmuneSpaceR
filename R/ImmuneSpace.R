.ISCon$methods(
  .munge=function(x){
    new <- tolower(gsub(" ","_",basename(x)))
    idx <- which(duplicated(new) | duplicated(new, fromLast = TRUE))
    if(length(idx)>0)
      new[idx] <- .munge(gsub("(.*)/.*$", "\\1", x[idx]))
    return(new)
  }
)

# Returns TRUE if the connection is at project level ("/Studies")
.ISCon$methods(
  .isProject=function()
    return( config$labkey.url.path == "/Studies/" )
)

.ISCon$methods(
  GeneExpressionInputs=function(){
    if( .self$.isProject() == TRUE){
      stop("con$GeneExpressionInputs() cannot be run at project level.")
    }else{
      if(!is.null(data_cache[[constants$matrix_inputs]])){
        data_cache[[constants$matrix_inputs]]
      }else{
        ge <- tryCatch(
          data.table(labkey.selectRows(baseUrl = config$labkey.url.base,
                                       folderPath = config$labkey.url.path,
                                       schemaName = "assay.ExpressionMatrix.matrix",
                                       queryName = "InputSamples",
                                       colNameOpt = "fieldname",
                                       viewName = "gene_expression_matrices",
                                       showHidden = TRUE)),
          error = function(e) return(e)
        )
        if( length(ge$message) > 0 ){
          stop("Gene Expression Inputs not found for study.")
        }
        setnames(ge,.self$.munge(colnames(ge)))
        data_cache[[constants$matrix_inputs]]<<-ge
      }
    }
  }
)


.ISCon$methods(
  .isRunningLocally=function(path){
    file.exists(path)
  }
)

.ISCon$methods(
  .localStudyPath=function(urlpath){
    LOCALPATH <- "/share/files/"
    PRODUCTION_HOST <- "www.immunespace.org"
    TEST_HOST <- "test.immunespace.org"
    gsub(file.path(gsub("/$","",config$labkey.url.base), "_webdav"), file.path(LOCALPATH), urlpath)
  }
)

.ISCon$methods(
  listDatasets=function(output = c("datasets", "expression")){
    "List the datasets available in the study or studies of the connection."
    
    if( !all(output %in% c("datasets", "expression")) ){
      stop("output other than datasets and expressions not allowed")
    }
    
    if("datasets" %in% output){

      cat("datasets\n")
      for(i in 1:nrow(available_datasets)){
        cat(sprintf("\t%s\n",available_datasets[i,Name]))
      }
    }
    
    if("expression" %in% output){
      if(!is.null(data_cache[[constants$matrices]])){
        cat("Expression Matrices\n")
        for(i in 1:nrow(data_cache[[constants$matrices]])){
          cat(sprintf("\t%s\n",data_cache[[constants$matrices]][i, name]))
        }
      }else{
        cat("No Expression Matrices Available")
      }
    }

  }
)

.ISCon$methods(
  listGEAnalysis = function(){
    "List available gene expression analysis for the connection."
    GEA <- tryCatch(
      data.table(labkey.selectRows(baseUrl = config$labkey.url.base,
                                   folderPath = config$labkey.url.path,
                                   schemaName = "gene_expression",
                                   queryName = "gene_expression_analysis",
                                   colNameOpt = "rname")),
      error = function(e) return(e)
    )
    if( length(GEA$message) > 0 ){
      stop("Study does not have Gene Expression Analyses.")
    }

    return(GEA)
  }
)

.ISCon$methods(
  getGEAnalysis = function(...){
    "Downloads data from the gene expression analysis results table.\n
    '...': A list of arguments to be passed to labkey.selectRows."
    GEAR <- tryCatch(
      data.table(labkey.selectRows(baseUrl = config$labkey.url.base, 
                                   folderPath = config$labkey.url.path,
                                   schemaName = "gene_expression", 
                                   queryName = "DGEA_filteredGEAR",  
                                   viewName = "DGEAR", 
                                   colNameOpt = "caption", ...)),
      error = function(e) return(e)
    )
    if( length(GEAR$message) > 0 ){
      stop("Gene Expression Analysis not found for study.")
    }
    
    setnames(GEAR, .self$.munge(colnames(GEAR)))
    return(GEAR)
  }
  )

.ISCon$methods(
  clear_cache = function(){
    "Clear the data_cache. Remove downloaded datasets and expression matrices."
    data_cache[grep("^GE", names(data_cache), invert = TRUE)] <<- NULL
  }
)

.ISCon$methods(
  show=function(){
    "Display information about the object."

    cat(sprintf("Immunespace Connection to study %s\n",study))
    cat(sprintf("URL: %s\n",
                file.path(gsub("/$","",config$labkey.url.base),
                          gsub("^/","",config$labkey.url.path))))
    cat(sprintf("User: %s\n",config$labkey.user.email))
    cat("Available datasets\n")
    for(i in 1:nrow(available_datasets)){
      cat(sprintf("\t%s\n",available_datasets[i,Name]))
    }
    if(!is.null(data_cache[[constants$matrices]])){
      cat("Expression Matrices\n")
      for(i in 1:nrow(data_cache[[constants$matrices]])){
        cat(sprintf("\t%s\n",data_cache[[constants$matrices]][i, name]))
      }
    }
  }
)

.ISCon$methods(
  getGEFiles=function(files, destdir = ".", quiet = FALSE){
    "Download gene expression raw data files.\n
    files: A character. Filenames as shown on the gene_expression_files dataset.\n
    destdir: A character. The loacal path to store the downloaded files."
    links <- paste0(config$labkey.url.base, "/_webdav/",
                    config$labkey.url.path,
                    "/%40files/rawdata/gene_expression/", files)
    sapply(links, function(x){
      download.file(url = links[1], 
                    destfile = file.path(destdir, basename(x)),
                    method = "curl", 
                    extra = "-n",
                    quiet = quiet)
    })
  }
)

#################################################################################
###                     MAINTAINENANCE FN                                     ###
#################################################################################

# Helper FNS --------------------------------------------------------------------
# get names of files in a single folder from webdav link
.listISFiles <- function(link){
  response <- NULL
  if (url.exists(url = link, netrc = TRUE)){
    response_raw <- getURL(url = link, netrc = TRUE)
    response_json <- fromJSON(response_raw)
    response <- unlist(lapply(response_json$files, function(x) x$text))
  }
  return(response)
}

# Generate named list of files in either rawdata or analysis/exprs_matrices folders
.getGEFileNms <- function(.self, rawdata){
  # create list of sdy folders
  studies <- labkey.getFolders(baseUrl = .self$config$labkey.url.base, 
                               folderPath = "/Studies/")
  studies <- studies[, 1]
  studies <- studies[ !studies %in% c("SDY_template","Studies") ]
  
  # check webdav folder for presence of rawdata
  file_list <- mclapply(studies, mc.cores = detectCores(), FUN = function(sdy){
    suffix <- ifelse(rawdata == TRUE,
                     "/%40files/rawdata/gene_expression?method=JSON",
                     "/%40files/analysis/exprs_matrices?method=JSON")
    dirLink <-  paste0(.self$config$labkey.url.base, 
                           "/_webdav/Studies/", 
                           sdy, 
                           suffix)
    files <- .listISFiles(dirLink)
    if(rawdata == TRUE){
      if( !is.null(files) ){ files <- length(files) > 0 }
    }
    return(files)
  })
  
  names(file_list) <- studies
  return(file_list)
}

# Returns a list of data frames where TRUE in file_exists column marks files that are accessible.
# This function is used for administrative purposes to check that the flat files
# are properly loaded and accessible to the users.
#' @importFrom RCurl getURL url.exists
#' @importFrom rjson fromJSON
#' @importFrom parallel mclapply detectCores
.ISCon$methods(
  .test_files=function(what = c("gene_expression_files", 
                                "fcs_sample_files", 
                                "protocols", 
                                "ge_matrices")){
    
    check_links <- function (dataset, folder){
      res <- data.frame(file_info_name = NULL, study_accession = NULL, 
                        file_link = NULL, file_exists = NULL, 
                        stringsAsFactors = FALSE)
      
      if (dataset %in% .self$available_datasets$Name){
        temp <- .self$getDataset(dataset, original_view = TRUE)
        temp <- temp[!is.na(file_info_name)]
        temp <- unique(temp[, list(study_accession, file_info_name)])
        
        file_link <- paste0(config$labkey.url.base, "/_webdav/Studies/", 
                            temp$study_accession, "/%40files/rawdata/", folder, "/", 
                            sapply(temp$file_info_name, URLencode))
        
        studies <- unique(temp$study_accession)
        folder_link <- paste0(config$labkey.url.base, "/_webdav/Studies/", 
                              studies, "/%40files/rawdata/", folder, "?method=JSON")
        
        file_list <- unlist(mclapply(folder_link, .listISFiles, mc.cores = detectCores()))
        
        file_exists <- temp$file_info_name %in% file_list
        res <- data.frame(study = temp$study_accession, file_link = file_link, file_exists = file_exists, 
                          stringsAsFactors = FALSE) 
        print(paste0(sum(res$file_exists), "/", nrow(res), " ", dataset, " with valid links."))
      }
      
      res
    }
    
    ret <- list()
    what <- tolower(what)
    
    if("gene_expression_files" %in% what){
      ret$gene_expression_files <- check_links("gene_expression_files", "gene_expression")
    }
    if("fcs_sample_files" %in% what){
      ret$fcs_sample_files <- check_links("fcs_sample_files", "flow_cytometry")
    }
    if("protocols" %in% what){
      if(.self$.isProject()){
        folders_list <- labkey.getFolders(baseUrl = config$labkey.url.base, 
                                          folderPath = "/Studies/")
        folders <- folders_list[, 1]
        folders <- folders[!folders %in% c("SDY_template","Studies")]
      } else{
        folders <- basename(config$labkey.url.path)
      }
      
      file_link <- paste0(config$labkey.url.base, "/_webdav/Studies/", folders, 
                          "/%40files/protocols/", folders, "_protocol.zip")
      file_exists <- unlist(mclapply(file_link, url.exists, netrc = TRUE, mc.cores = detectCores()))
      
      res <- data.frame(study = folders, file_link = file_link, file_exists = file_exists, 
                        stringsAsFactors = FALSE)      
      print(paste0(sum(res$file_exists), "/", nrow(res), " protocols with valid links."))
      ret$protocols <- res
    }
    if ("ge_matrices" %in% what){
      matrix_queries <- labkey.getQueries(baseUrl = config$labkey.url.base, 
                                          folderPath = config$labkey.url.path, 
                                          schemaName = "assay.ExpressionMatrix.matrix")
      
      if ("OutputDatas" %in% matrix_queries$queryName) {
        ge <- data.frame( labkey.selectRows(baseUrl = config$labkey.url.base,
                                            folderPath = config$labkey.url.path,
                                            schemaName = "assay.ExpressionMatrix.matrix",
                                            queryName = "OutputDatas",
                                            colNameOpt = "rname",
                                            viewName = "links"))
        
        output <- lapply(ge[4], function(x) gsub("@", "%40", gsub("file:/share/files", 
                                                                  paste0(config$labkey.url.base, 
                                                                         "/_webdav"), x)))

        file_exists <- unlist(mclapply(output$data_datafileurl, 
                                       url.exists, 
                                       netrc = TRUE, 
                                       mc.cores = detectCores()))
        res <- data.frame(file_link = output$data_datafileurl, 
                          file_exists = file_exists, 
                          stringsAsFactors = FALSE)

        print(paste0(sum(res$file_exists), "/", nrow(res), " ge_matrices with valid links."))
      } else {
        res <- data.frame(file_link = NULL, file_exists = NULL, stringsAsFactors = FALSE)
      }
      
      ret$ge_matrices <- res
    }
    return(ret)
  }
)

#-------------------GEM CLEANUP------------------------------------
# This function outputs a list of lists.  There are six possible sub-lists >
# 1. $gemAndRaw = study has gene expression matrix flat file and raw data
# 2. $gemNoRaw = study has gene expression matrix flat file but no raw data (unlikely)
# 3. $rawNoGem = study has raw data but no gene expression flat file, which is likely
#                in the case that no annotation pkg is availble in bioconductor or
#                it is RNAseq and had trouble being processed.
# 4. $gefNoGem = con$getDataset("gene_expression_files") reports raw data available, but
#                no gene expression matrix flat file has been generated. Similar to rawNoGem.
# 5. $gefNoRaw = con$getDataset() reports files being available, but no rawdata found.  This
#                may be due to files being in GEO, but not having been downloaded to ImmPort
#                and ImmuneSpace.
# 6. $rawNoGef = This would be unexpected. Rawdata present on server, but no gene expression
#                files found by con$getDataset().
.ISCon$methods(
  .sdysWithoutGems = function(){
    
    res <- list()
    
    spSort <- function(vec){
      if(length(vec) > 0 ){
        vec <- sort(as.numeric(gsub("SDY","",vec)))
        vec <- paste0("SDY", as.character(vec))
      }else{
        vec <- NULL
      }
    }
    
    # get list of matrices and determine which sdys they represent
    gems <- .self$data_cache$GE_matrices
    withGems <- unique(gems$folder)
    
    file_list <- .getGEFileNms(.self = .self, rawdata = TRUE)
    file_list <- file_list[ file_list != "NULL" ]
    emptyFolders <- names(file_list)[ file_list == FALSE ]
    withRawData <- names(file_list)[ file_list == TRUE ]
    
    # Compare lists
    res$gemAndRaw <- spSort(intersect(withRawData, withGems))
    res$gemNoRaw <- spSort(setdiff(withGems, withRawData))
    res$rawNoGem <- spSort(setdiff(withRawData, withGems))
    
    # Check which studies without gems have gef in IS
    ge <- con$getDataset("gene_expression_files")
    geNms <- unique(ge$participant_id)
    gefSdys <- unique(sapply(geNms, FUN = function(x){
      res <- strsplit(x, ".", fixed = T)
      return(res[[1]][2])
    }))
    gefSdys <- paste0("SDY", gefSdys)
    
    res$gefNoGem <- spSort(gefSdys[ !(gefSdys %in% withGems) ])
    res$gefNoRaw <- spSort(setdiff(res$gefNoGem, res$rawNoGem))
    res$rawNoGef <- spSort(setdiff(res$rawNoGem, res$gefNoGem))
    
    return( res )
  }
)

# Remove gene expression matrices that do not correspond to a run currently on prod or test
# in the query assay.ExpressionMatrix.matrix.Runs. NOTE: Important to change the labkey.url.base 
# variable depending on prod / test to ensure you are not deleting any incorrectly.
#' @importFrom RCurl httpDELETE
.ISCon$methods(
  .rmOrphanGems = function(){
    
    .getNoRunPres <- function(.self, runs){
      # get flat files list with appropriate names (sdy)
      emFls <- .getGEFileNms(.self = .self, rawdata = FALSE)
      emFls <- emFls[ emFls != "NULL" ]
      tmpNms <- rep(x = names(emFls), times = lengths(emFls))
      emFls <- unlist(emFls)
      names(emFls) <- tmpNms
      
      # get names from emFls for comparison
      emNms <- sapply(emFls, FUN = function(x){
        return( strsplit(x, "\\.tsv")[[1]][1] )
      })
      
      # check runs for file names - assume if not in runs$Name then ok to delete!
      noRunPres <- emNms[ !(emNms %in% runs$Name) ]
      noRunPres <- noRunPres[ !duplicated(noRunPres) ]
    }
    
    # helper curl FN
    curlDelete <- function(baseNm, sdy, .self){
      opts <- .self$config$curlOptions
      opts$netrc <- 1L
      handle <- getCurlHandle(.opts = opts)
      tsv <-  paste0(.self$config$labkey.url.base, 
                     "/_webdav/Studies/", 
                     sdy, 
                     "/%40files/analysis/exprs_matrices/",
                     baseNm,
                     ".tsv")
      smry <- paste0(tsv, ".summary")
      tsvRes <- tryCatch(
        httpDELETE(url = tsv, curl = handle),
        error = function(e) return(FALSE)
      )
      smryRes <- tryCatch(
        httpDELETE(url = smry, curl = handle),
        error = function(e) return(FALSE)
      )
    }
    
    # Double check we are working at project level and on correct server!
    if( .self$.isProject() == FALSE){ stop("Can only be run at project level") }
    chkBase <- readline(prompt = paste0("You are working on ",
                                        .self$config$labkey.url.base,
                                        ". Continue? [T / f] "))
    if( !(chkBase %in% c("T","t",""))){ return("Operation Aborted.") }
    
    # get runs listed in the proper table
    runs <- data.table( labkey.selectRows( baseUrl = .self$config$labkey.url.base,
                                           folderPath = .self$config$labkey.url.path,
                                           schemaName = "assay.ExpressionMatrix.matrix",
                                           queryName = "Runs",
                                           showHidden = T))
    
    noRunPres <- .getNoRunPres(.self = .self, runs = runs)
    
    # if files to-be-rm, confirm rm ok, attempt delete, check results and report
    if( length(noRunPres) == 0){ 
      return("No orphans found. Hurray!")
    }else{
      print(noRunPres)
    }
    ok2rm <- readline(prompt = "Ok to remove all files listed above? [Y / n] ")
    if(toupper(ok2rm) == "Y" | ok2rm == ""){
      for(i in 1:length(noRunPres)){
        curlDelete(baseNm = noRunPres[i],
                   sdy = names(noRunPres)[i],
                   .self = .self)
      }
      noRunPresPost <- .getNoRunPres(.self = .self, runs = runs)
      if( length(noRunpresPost) == 0){ 
        return("No orphans found after removal. Success!")
      }else{
        print("Problems Occurred. Remaining Files with No Runs Present")
        print(noRunPresPost)
        print("************")
      }
    }else{
      print("Operation aborted.")
    }
  }
)
