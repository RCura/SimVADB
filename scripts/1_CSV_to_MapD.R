library(tidyverse)
library(stringr)
library(DBI)
library(RJDBC)
library(ssh)

######################################
############# PARAMETRES #############
######################################

outputs_path <- "/data/user/c/rcura/"
setwd(outputs_path)

prefixe_files <- "5_1_PopInit"
sim_name <- "5_1_Pop"
suffixe_tables <- "_5_1"
nb_replications_to_keep <- 20

options( java.parameters = c("-Xss2560k", "-Xmx8g") ) # Needed fix for rJava (JDBC) + ggplot2

conMapD <- NULL
connectToMapD <- function(){
  conMapD <<- dbConnect(drv = JDBC("com.mapd.jdbc.MapDDriver",
                                   "/data/user/c/rcura/mapd-1.0-SNAPSHOT-jar-with-dependencies.jar",
                                   identifier.quote="'"),
                        "jdbc:mapd:mapdi.cura.info:9091:mapd", "mapd", "HyperInteractive")
}
session_ssh <- ssh_connect("rcura@mapd.cura.info")

########################################################
############# ON ISOLE LES SEEDS CORRECTES #############
########################################################

set.seed(2)
finished_seeds <- read_csv(file = sprintf("%s_results_global.csv", prefixe_files)) %>%
  mutate(sim_name = !!sim_name) %>%
  filter(Annee == 1160) %>%
  mutate(seed = as.character(myseed)) %>%
  pull(seed)


params <- read_csv(file = sprintf("%s_parameters.csv", prefixe_files)) %>%
  mutate(sim_name = !!sim_name) %>%
  mutate(seed = as.character(myseed)) %>%
  select(-myseed) %>%
  filter(seed %in% finished_seeds) %>%
  group_by_at(vars(-seed)) %>%
  mutate(unique_experiment = runif(n = 1)) %>%
  ungroup()

nb_experiments <- params %>%
  select(seed, unique_experiment) %>%
  group_by(unique_experiment) %>%
  nrow()
if (nb_experiments > nb_replications_to_keep){
  seeds_to_keep <- params %>%
    select(seed, unique_experiment) %>%
    group_by(unique_experiment) %>%
    sample_n(nb_replications_to_keep) %>%
    pull(seed)
} else {
  seeds_to_keep <- params %>%
    select(seed, unique_experiment) %>%
    group_by(unique_experiment) %>%
    pull(seed)
}
rm(finished_seeds)

#########################################################
############# ON NETTOIE ET ENVOI DANS MAPD #############
#########################################################

############# PARAMETERS #############

params <- read_csv(file = sprintf("%s_parameters.csv", prefixe_files)) %>%
  rename(seed = myseed) %>%
  mutate(seed = as.character(seed)) %>%
  filter(seed %in% seeds_to_keep) %>%
  mutate(sim_name = !!sim_name)
  

params_mapd <- params %>%
  rename_all(funs(tolower(.x))) %>%
  mutate(serfs_mobiles = if_else(serfs_mobiles == "true", 1L, 0L))

fileToWrite <- sprintf("~/mapd-docker-storage/data/mapd_import/%s_MapD_parameters.csv.bz2", prefixe_files)
fileToRead <- str_replace(fileToWrite, pattern = "~/mapd-docker-storage/", replacement = "/mapd-storage/")

write_csv(params_mapd, fileToWrite)
scp_upload(session = session_ssh, files = fileToWrite, to = "~/mapd-docker-storage/data/mapd_import/")
file.remove(fileToWrite)

connectToMapD()
sprintf("COPY parameters%s FROM '%s';", suffixe_tables, fileToRead)
sqlQuery <- DBI::dbSendQuery(conn = conMapD, sprintf("COPY parameters%s FROM '%s';", suffixe_tables, fileToRead))
print(DBI::dbFetch(sqlQuery))
dbDisconnect(conMapD)

rm(params, params_mapd, sqlQuery)


############# AGREGATS #############

results_agregats <- read_csv(file = sprintf("%s_results_agregats.csv", prefixe_files)) %>%
  rename(seed = myseed) %>%
  mutate(seed = as.character(seed)) %>%
  filter(seed %in% seeds_to_keep) %>%
  mutate(sim_name = !!sim_name)

agregats_mapd <- results_agregats %>%
  rename(annee = Annee,
         nbfp = nbFP) %>%
  select(id_agregat,
         seed,
         sim_name,
         annee,
         nbfp,
         superficie,
         communaute,
         monpole) %>%
  mutate(communaute = if_else(communaute == "true", 1L, 0L))

nb_agregats <- agregats_mapd %>%
  group_by(seed, sim_name, annee) %>%
  tally() %>%
  rename(nbagregats = n)

fileToWrite <- sprintf("~/mapd-docker-storage/data/mapd_import/%s_MapD_agregats.csv.bz2", prefixe_files)
fileToRead <- str_replace(fileToWrite, pattern = "~/mapd-docker-storage/", replacement = "/mapd-storage/")

write_csv(agregats_mapd, fileToWrite)
scp_upload(session = session_ssh, files = fileToWrite, to = "~/mapd-docker-storage/data/mapd_import/")
file.remove(fileToWrite)

connectToMapD()
sprintf("COPY agregats%s FROM '%s';", suffixe_tables, fileToRead)
sqlQuery <- DBI::dbSendQuery(conn = conMapD, sprintf("COPY agregats%s FROM '%s';", suffixe_tables, fileToRead))
print(DBI::dbFetch(sqlQuery))
dbDisconnect(conMapD)

rm(results_agregats, agregats_mapd, sqlQuery)

############# GLOBAL #############

results_global <-read_csv(file = sprintf("%s_results_global.csv", prefixe_files)) %>%
  rename(seed = myseed) %>%
  mutate(seed = as.character(seed)) %>%
  filter(seed %in% seeds_to_keep) %>%
  mutate(sim_name = !!sim_name)


results_mapd <- results_global %>%
  rename_all(funs(tolower(.x))) %>%
  left_join(nb_agregats, by = c("seed", "sim_name", "annee")) %>%
  left_join(results_global %>%
              rename(annee = Annee) %>%
              filter(annee == 840) %>%
              rename(cf_base = charge_fiscale) %>%
              select(seed,cf_base), by = "seed") %>%
  mutate(ratiochargefiscale = if_else(annee == 820, 0, charge_fiscale / cf_base)) %>%
  select(-cf_base)

fileToWrite <- sprintf("~/mapd-docker-storage/data/mapd_import/%s_MapD_results.csv.bz2", prefixe_files)
fileToRead <- str_replace(fileToWrite, pattern = "~/mapd-docker-storage/", replacement = "/mapd-storage/")

write_csv(results_mapd, fileToWrite)
scp_upload(session = session_ssh, files = fileToWrite, to = "~/mapd-docker-storage/data/mapd_import/")
file.remove(fileToWrite)

connectToMapD()
sprintf("COPY results%s FROM '%s';", suffixe_tables, fileToRead)
sqlQuery <- DBI::dbSendQuery(conn = conMapD, sprintf("COPY results%s FROM '%s';", suffixe_tables, fileToRead))
print(DBI::dbFetch(sqlQuery))
dbDisconnect(conMapD)

#rm(results_global, results_mapd, sqlQuery)

############# SEEDS #############
seeds_mapd <- results_mapd %>%
  select(seed, sim_name) %>%
  group_by(seed, sim_name) %>%
  tally() %>%
  ungroup() %>%
  select(-n)

fileToWrite <- sprintf("~/mapd-docker-storage/data/mapd_import/%s_MapD_seeds.csv.bz2", prefixe_files)
fileToRead <- str_replace(fileToWrite, pattern = "~/mapd-docker-storage/", replacement = "/mapd-storage/")

write_csv(seeds_mapd, fileToWrite)
scp_upload(session = session_ssh, files = fileToWrite, to = "~/mapd-docker-storage/data/mapd_import/")
file.remove(fileToWrite)

connectToMapD()
sprintf("COPY seeds%s FROM '%s';", suffixe_tables, fileToRead)
sqlQuery <- DBI::dbSendQuery(conn = conMapD, sprintf("COPY seeds%s FROM '%s';", suffixe_tables, fileToRead))
print(DBI::dbFetch(sqlQuery))
dbDisconnect(conMapD)


rm(results_global, results_mapd, seeds_mapd, nb_agregats,sqlQuery)

############# SEIGNEURS #############

results_seigneurs <- read_csv(file = sprintf("%s_results_seigneurs.csv", prefixe_files)) %>%
  rename(seed = myseed) %>%
  mutate(seed = as.character(seed)) %>%
  filter(seed %in% seeds_to_keep) %>%
  mutate(sim_name = !!sim_name)

seigneurs_mapd <- results_seigneurs %>%
  rename_all(funs(tolower(.x))) %>%
  select(id_seigneur, everything(), -geom) %>%
  mutate(initial = if_else(initial == "true", 1L, 0L))

fileToWrite <- sprintf("~/mapd-docker-storage/data/mapd_import/%s_MapD_seigneurs.csv.bz2", prefixe_files)
fileToRead <- str_replace(fileToWrite, pattern = "~/mapd-docker-storage/", replacement = "/mapd-storage/")

write_csv(seigneurs_mapd, fileToWrite)
scp_upload(session = session_ssh, files = fileToWrite, to = "~/mapd-docker-storage/data/mapd_import/")
file.remove(fileToWrite)

connectToMapD()
sprintf("COPY seigneurs%s FROM '%s';", suffixe_tables, fileToRead)
sqlQuery <- DBI::dbSendQuery(conn = conMapD, sprintf("COPY seigneurs%s FROM '%s';", suffixe_tables, fileToRead))
print(DBI::dbFetch(sqlQuery))
dbDisconnect(conMapD)

rm(results_seigneurs, seigneurs_mapd, sqlQuery)

############# PAROISSES #############

results_paroisses <- read_csv(file = sprintf("%s_results_paroisses.csv", prefixe_files)) %>%
  rename(seed = myseed) %>%
  mutate(seed = as.character(seed)) %>%
  filter(seed %in% seeds_to_keep) %>%
  mutate(sim_name = !!sim_name)

paroisses_mapd <- results_paroisses %>%
  rename_all(funs(tolower(.x))) %>%
  rename(area = shape.area) %>%
  select(id_paroisse, seed, sim_name, annee,
         moneglise, mode_promotion, area,
         nbfideles, satisfactionparoisse)

fileToWrite <- sprintf("~/mapd-docker-storage/data/mapd_import/%s_MapD_paroisses.csv.bz2", prefixe_files)
fileToRead <- str_replace(fileToWrite, pattern = "~/mapd-docker-storage/", replacement = "/mapd-storage/")

write_csv(paroisses_mapd, fileToWrite)
scp_upload(session = session_ssh, files = fileToWrite, to = "~/mapd-docker-storage/data/mapd_import/")
file.remove(fileToWrite)

connectToMapD()
sprintf("COPY paroisses%s FROM '%s';", suffixe_tables, fileToRead)
sqlQuery <- DBI::dbSendQuery(conn = conMapD, sprintf("COPY paroisses%s FROM '%s';", suffixe_tables, fileToRead))
print(DBI::dbFetch(sqlQuery))
dbDisconnect(conMapD)

rm(results_paroisses, paroisses_mapd, sqlQuery)

############# POLES #############

results_poles <- read_csv(file = sprintf("%s_results_poles.csv", prefixe_files)) %>%
  rename(seed = myseed) %>%
  mutate(seed = as.character(seed)) %>%
  filter(seed %in% seeds_to_keep) %>%
  mutate(sim_name = !!sim_name)

poles_mapd <- results_poles %>%
  rename_all(funs(tolower(.x))) %>%
  select(id_pole, seed, sim_name, annee,
         everything()) %>%
  select(-geom)

fileToWrite <- sprintf("~/mapd-docker-storage/data/mapd_import/%s_MapD_poles.csv.bz2", prefixe_files)
fileToRead <- str_replace(fileToWrite, pattern = "~/mapd-docker-storage/", replacement = "/mapd-storage/")

write_csv(poles_mapd, fileToWrite)
scp_upload(session = session_ssh, files = fileToWrite, to = "~/mapd-docker-storage/data/mapd_import/")
file.remove(fileToWrite)

connectToMapD()
sprintf("COPY poles%s FROM '%s';", suffixe_tables, fileToRead)
sqlQuery <- DBI::dbSendQuery(conn = conMapD, sprintf("COPY poles%s FROM '%s';", suffixe_tables, fileToRead))
print(DBI::dbFetch(sqlQuery))
dbDisconnect(conMapD)

rm(results_poles, poles_mapd, sqlQuery)

############# FP #############

results_fp <- read_csv(file = sprintf("%s_results_FP.csv", prefixe_files)) %>%
  rename(seed = myseed) %>%
  mutate(seed = as.character(seed)) %>%
  filter(seed %in% seeds_to_keep) %>%
  mutate(sim_name = !!sim_name)


fp_mapd <- results_fp %>%
  select(id_fp, seed, sim_name, Annee, communaute, monagregat,
         sMat, sRel, sProt, Satis, mobile, type_deplacement,
         deplacement_from, deplacement_to, nb_preleveurs) %>%
  rename(annee = Annee,
         smat = sMat,
         srel = sRel,
         sprot = sProt,
         satis = Satis) %>%
  mutate(communaute = if_else(communaute == "true", 1L, 0L),
         mobile = if_else(mobile == "true", 1L, 0L)
  )

fileToWrite <- sprintf("~/mapd-docker-storage/data/mapd_import/%s_MapD_FP.csv.bz2", prefixe_files)
fileToRead <- str_replace(fileToWrite, pattern = "~/mapd-docker-storage/", replacement = "/mapd-storage/")

write_csv(fp_mapd, fileToWrite)
scp_upload(session = session_ssh, files = fileToWrite, to = "~/mapd-docker-storage/data/mapd_import/")
file.remove(fileToWrite)

connectToMapD()
sprintf("COPY fp%s FROM '%s';", suffixe_tables, fileToRead)
sqlQuery <- DBI::dbSendQuery(conn = conMapD, sprintf("COPY fp%s FROM '%s';", suffixe_tables, fileToRead))
print(DBI::dbFetch(sqlQuery))
dbDisconnect(conMapD)

rm(results_fp, fp_mapd, sqlQuery)

ssh_disconnect(session = session_ssh)
rm(session_ssh)
#########
# TESTS #
#########



nonUniqueParams <- params %>%
    gather(key = "Var", value = "Value") %>%
    group_by(Var, Value) %>%
    mutate(Freq = n()) %>%
    ungroup() %>%
    filter(Freq != nrow(params)) %>%
    distinct(Var) %>%
    pull(Var)
  
  params %>% dplyr::select(!!nonUniqueParams)
  
  
  
  #####
  params_augmented <- read_csv("~/params_4_5_mapd.csv", quote = '"') %>%
    mutate(taille_cote_monde = 100) %>%
    mutate_all(.funs = funs(as.character))
  write.csv(params_augmented, "~/mapd-docker-storage/data/mapd_import/params_augmented_4_5.csv", quote = TRUE, row.names = FALSE)
  
  
  connectToMapD()
  sqlQuery <- DBI::dbSendQuery(conn = conMapD, "COPY param_test2 FROM '/mapd-storage/data/mapd_import/params_augmented_4_5.csv';")
  print(DBI::dbFetch(sqlQuery))
  dbDisconnect(conMapD)
  