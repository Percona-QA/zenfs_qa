#!/bin/bash
###################################################################################
# This script is created to test ZenFS backup and restore facility supported only #
# for RocksDB engine. The script uses pstress to generate the load on PS.         #
# The script can generate any size of load. As part of this test, we are creating #
# 1000 tables, 1000 records per table. It then takes backup and restore it        #
# using the ZenFS mount points nvm1n2 and nvm0n2                                  #
#                                                                                 #
# Created by: Mohit Joshi <mohit.joshi@percona.com>                               #
# Created on: 12-Jan-2022                                                         #
###################################################################################

MYSQLD_START_TIMEOUT=300
BASEDIR=$HOME/mysql-8.0/bld_zenfs/install
PSTRESS=$HOME/pstress/src
NO_OF_TABLES=1000
NO_OF_RECORDS=1000

# Kill any existing mysqld process
KILLPID=$(ps -ef | grep "22000.sock" | grep -v grep | awk '{print $2}' | tr '\n' ' ')
  (sleep 0.2; kill -9 $KILLPID >/dev/null 2>&1; timeout -k4 -s9 4s wait $KILLPID >/dev/null 2>&1) &

# Remove Auxillary directory if exists
rm -rf $HOME/aux_nvme1n2
rm -rf $HOME/aux_nvme0n2

# Remove any existing datadir
rm -rf $BASEDIR/data_original

# Remove data backup location
rm -rf $HOME/zenfs_backup
echo "Backup directory $HOME/zenfs_backup created"
mkdir $HOME/zenfs_backup

# Create ZenFS mount point for data storage
zenfs mkfs --zbd nvme1n2 --aux_path=/home/mohit.joshi/aux_nvme1n2 --force
echo "Mount point nvme1n2 created"

# Data directory initialisation
${BASEDIR}/bin/mysqld --no-defaults --datadir=$BASEDIR/data_original --initialize-insecure > /dev/null 2>&1
echo "Data directory created"

# Start server
${BASEDIR}/bin/mysqld --no-defaults --datadir=$BASEDIR/data_original --port=22000 --socket=/tmp/mysql_22000.sock --max-connections=1024 --log-error --general-log --log-error-verbosity=3 --core-file --loose-rocksdb-fs-uri=zenfs://dev:nvme1n2 &

for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
  sleep 1
  echo "Server start in progress..."
  if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/mysql_22000.sock ping > /dev/null 2>&1; then
    echo "Server started successfully"
    break
  fi
done

# Install RocksDB 
${BASEDIR}/bin/ps-admin --enable-rocksdb -uroot -S/tmp/mysql_22000.sock > /dev/null 2>&1
echo "RocksDB installed successfully"

# Create test database
$BASEDIR/bin/mysql --no-defaults -S/tmp/mysql_22000.sock -uroot -e"create database test";

# pstress runs
echo "Starting pstress runs"
$PSTRESS/pstress-ps --tables $NO_OF_TABLES --records $NO_OF_RECORDS --seconds 1 --no-partition-tables --no-temp-tables --indexes 0 --special-sql 0 --logdir=$PSTRESS/log --socket /tmp/mysql_22000.sock --threads 10 --log-all-queries --log-failed-queries --engine=RocksDB --exact-initial-records --select-single-row 10 --only-cl-sql

echo "Data inserted successfully"

# validate number of tables
$BASEDIR/bin/mysql --no-defaults -S/tmp/mysql_22000.sock -uroot --database=test -e"show tables";

# validate no. of records in each table
for X in $(seq 1 $NO_OF_TABLES); do
  $BASEDIR/bin/mysql --no-defaults -S/tmp/mysql_22000.sock -uroot --database=test -e"select count(*) from tt_$X";
done

# Shutdown server
echo "Shutting down server"
$BASEDIR/bin/mysqladmin -uroot -S/tmp/mysql_22000.sock shutdown > /dev/null 2>&1

sleep 10;

# Take backup
echo "Taking ZenFS backup"
zenfs backup --zbd=nvme1n2 --path=/home/mohit.joshi/zenfs_backup --backup_path=./

# Create new ZenFS mount point for data restore
echo "Creating new ZenFS mount point"
zenfs mkfs --zbd nvme0n2 --aux_path=/home/mohit.joshi/aux_nvme0n2 --force
echo "Mount point nvme0n2 created"

# Restore data
echo "Restoring data"
zenfs restore --zbd=nvme0n2 --path=/home/mohit.joshi/zenfs_backup/ --restore_path=.

# Start the server
echo "Starting server..."
$BASEDIR/bin/mysqld --no-defaults --datadir=$BASEDIR/data_original --port=22000 --socket=/tmp/mysql_22000.sock --max-connections=1024 --log-error --general-log --log-error-verbosity=3 --core-file --loose-rocksdb-fs-uri=zenfs://dev:nvme0n2 &

for X in $(seq 0 ${MYSQLD_START_TIMEOUT}); do
  sleep 1
  echo "Server start in progress..."
  if ${BASEDIR}/bin/mysqladmin -uroot -S/tmp/mysql_22000.sock ping > /dev/null 2>&1; then
    echo "Server started successfully"
    break
  fi
done

# validate number of tables
$BASEDIR/bin/mysql --no-defaults -S/tmp/mysql_22000.sock -uroot --database=test -e"show tables";

# validate no. of records in each table
for X in $(seq 1 $NO_OF_TABLES); do
  $BASEDIR/bin/mysql --no-defaults -S/tmp/mysql_22000.sock -uroot --database=test -e"select count(*) from tt_$X";
done
