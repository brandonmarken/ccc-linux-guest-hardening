#!/bin/bash

# 
# Copyright (C)  2022  Intel Corporation. 
#
# This software and the related documents are Intel copyrighted materials, and your use of them is governed by the express license under which they were provided to you ("License"). Unless the License provides otherwise, you may not use, modify, copy, publish, distribute, disclose or transmit this software or the related documents without Intel's prior written permission.
# This software and the related documents are provided as is, with no express or implied warranties, other than those that are expressly stated in the License.
#
# SPDX-License-Identifier: MIT

#
# Launcher for TDX/kAFL fuzzing + diagnostics
# 

BIOS_IMAGE=$BKC_ROOT/TDVF.fd
INITRD_IMAGE=$BKC_ROOT/initrd.cpio.gz
SHARE_DIR=$BKC_ROOT/sharedir
DEFAULT_WORK_DIR=$KAFL_WORKDIR
#DISK_IMAGE=$BKC_ROOT/tdx_overlay1.qcow2

# limited to 1G due to hardcoded TdHobList in TDVF!
MEMSIZE=1024

KAFL_FULL_OPTS="--redqueen --redqueen-hammer --redqueen-simple --grimoire --radamsa -p 2"
KAFL_QUICK_OPTS="--redqueen --redqueen-simple -D -p 2"


# enable TDX workaround in Qemu
export QEMU_BIOS_IN_RAM=1

# virtfs needs some default folder to serve to guest
test -d /tmp/kafl || mkdir /tmp/kafl

function usage()
{
	cat << HERE

Usage: $0 <cmd> <dir> [args]

Available commands <cmd>:
  run    <target> [args] - launch fuzzer with optional kAFL args [args]
  single <target> <file> - execute target from <dir> with single input from <file>
  debug  <target> <file> - launch target with single input <file>
                           and wait for gdb connection (qemu -s -S)
  cov <workdir>          - re-execute all payloads from <workdir>/corpus/ and
                           collect the individual trace logs to <workdir>/trace/
  smatch <workdir>       - get addr2line and smatch_match results from traces

<target> is a folder with vmlinux, System.map and bzImage
<workdir> is the output of a prior fuzzing run (default: $DEFAULT_WORK_DIR).

On 'run', the target files are copied to <workdir>/target for later diagnostics.
HERE
	exit
}

function fatal()
{
	echo $1
	usage
	exit
}

function get_addr_lower
{
	echo "0x$(grep $1 $TARGET_MAP|head -1|cut -b -13)000"
}

function get_addr_upper
{
	printf "0x%x\n" $(( $(get_addr_lower $1) + 0x1000))
}

# arg1 is the System.map
function get_ip_regions
{
	# tracing is sensitive to size, padding, runtime rewrites..
	ip0_name="text"
	ip0_a=$(get_addr_lower _stext)
	ip0_b=$(get_addr_upper _etext)
	#ip0_b=$(get_addr_upper __entry_text_end)

	ip1_name="inittext"
	ip1_a=$(get_addr_lower _sinittext)
	ip1_b=$(get_addr_upper _einittext)
	#ip1_b=$(get_addr_upper __irf_end)

	ip2_name="drivers(??)"
	ip2_a=$(get_addr_lower early_dynamic_pgts)
	ip2_b=$(get_addr_lower __bss_start)
	#ip1_b=$(get_addr_lower __bss_start)
}

# regular fuzz run based on TARGET_ROOT and default WORK_DIR
function run()
{
	get_ip_regions

	echo "PT trace regions:"
	echo "$ip0_a-$ip0_b ($ip0_name)"
	echo "$ip1_a-$ip1_b ($ip1_name)"
	echo "$ip2_a-$ip2_b ($ip2_name) // disabled"

	# failsafe: make sure we only delete fuzzer workdirs!
	test -d $WORK_DIR/corpus && rm -rf $WORK_DIR

	## record current setup and TARGET_ROOT/ assets to WORK_DIR/target/
	mkdir -p $WORK_DIR/target || fatal "Could not create folder $WORK_DIR/target"
	date > $WORK_DIR/target/timestamp.log
	cp $TARGET_BIN $TARGET_MAP $TARGET_ELF $WORK_DIR/target/
	cp $TARGET_BIN $TARGET_MAP $TARGET_ELF $WORK_DIR/target/
	echo "kAFL options: -m $MEMSIZE -ip0 $ip0_a-$ip0_b -ip1 $ip1_a-$ip1_b $KAFL_OPTS $*" > $WORK_DIR/target/kafl_args.txt

	## collect some more detailed target-specific info to help reproduce
	echo "Collecting target info from ${TARGET_ROOT}.."
	pushd $TARGET_ROOT > /dev/null
		cp .config $WORK_DIR/target/config
		test -f filtered_smatch_warns && cp filtered_smatch_warns $WORK_DIR/target/smatch_warns.txt
		git log --pretty=oneline -4 > $WORK_DIR/target/repo_log
		git diff > $WORK_DIR/target/repo_diff
	popd  > /dev/null

	echo "Launching kAFL with workdir ${WORK_DIR}.."
	kafl_fuzz.py \
		--memory $MEMSIZE \
		-ip0 $ip0_a-$ip0_b \
		-ip1 $ip1_a-$ip1_b \
		--bios $BIOS_IMAGE \
		--initrd $INITRD_IMAGE \
		--kernel $TARGET_BIN \
		--work-dir $WORK_DIR \
		--sharedir $SHARE_DIR \
		$KAFL_OPTS $*
}

function debug()
{
	TARGET_PAYLOAD="$1"
	shift || fatal "Missing argument <file>"
	test -f "$TARGET_PAYLOAD" || fatal "Provided <file> is not a regular file: $TARGET_PAYLOAD"

	echo -e "\033[33m"
	echo "Resume from workdir: $WORK_DIR"
	echo "Target kernel location:  $TARGET_BIN"
	echo -e "\033[00m"

	kafl_debug.py \
		--resume --memory $MEMSIZE \
		--bios $BIOS_IMAGE \
		--initrd $INITRD_IMAGE \
		--kernel $TARGET_BIN \
		--work-dir $WORK_DIR \
		--sharedir $SHARE_DIR \
		--action gdb --input $TARGET_PAYLOAD $*
}

function single()
{
	TARGET_PAYLOAD="$1"
	shift || fatal "Missing argument <file>"
	test -f "$TARGET_PAYLOAD" || fatal "Provided <file> is not a regular file: $TARGET_PAYLOAD"

	echo "Executing $TARGET_PAYLOAD"

	get_ip_regions

	kafl_debug.py \
		--resume --memory $MEMSIZE \
		-ip0 $ip0_a-$ip0_b \
		-ip1 $ip1_a-$ip1_b \
		--bios $BIOS_IMAGE \
		--initrd $INITRD_IMAGE \
		--kernel $TARGET_BIN \
		--work-dir $WORK_DIR \
		--sharedir $SHARE_DIR \
		--action single -n 1 --input $TARGET_PAYLOAD $*
}

function noise()
{
	TARGET_PAYLOAD="$1"
	shift || fatal "Missing argument <file>"
	test -f "$TARGET_PAYLOAD" || fatal "Provided <file> is not a regular file: $TARGET_PAYLOAD"


	get_ip_regions

	echo
	echo "Checking feedback noise on payload $TARGET_PAYLOAD"
	echo "Resume from workdir: $WORK_DIR"
	echo
	sleep 1

	kafl_debug.py \
		--resume --memory $MEMSIZE \
		-ip0 $ip0_a-$ip0_b \
		-ip1 $ip1_a-$ip1_b \
		--bios $BIOS_IMAGE \
		--initrd $INITRD_IMAGE \
		--kernel $TARGET_BIN \
		--work-dir $WORK_DIR \
		--sharedir $SHARE_DIR \
		--action noise -n 1000 --input $TARGET_PAYLOAD $*
}

function cov()
{
	echo
	echo "Resume from workdir: $WORK_DIR"
	echo
	sleep 1

	get_ip_regions

	echo "PT trace regions:"
	echo "$ip0_a-$ip0_b ($ip0_name)"
	echo "$ip1_a-$ip1_b ($ip1_name)"
	echo "$ip2_a-$ip2_b ($ip2_name) // disabled"
	sleep 2

	kafl_cov.py \
		--resume --memory $MEMSIZE \
		-ip0 $ip0_a-$ip0_b \
		-ip1 $ip1_a-$ip1_b \
		--bios $BIOS_IMAGE \
		--initrd $INITRD_IMAGE \
		--kernel $TARGET_BIN \
		--work-dir $WORK_DIR \
		--sharedir $SHARE_DIR \
		--input $WORK_DIR --log_hprintf $*
}

function smatch()
{
	# match smatch report against line coverage reported in addr2line.lst
	SMATCH_OUTPUT=$WORK_DIR/traces/smatch_match.lst

	$BKC_ROOT/bkc/kafl/gen_addr2line.sh $WORK_DIR
	$BKC_ROOT/bkc/kafl/smatch_match.py $WORK_DIR |sort -u > $SMATCH_OUTPUT
	echo "Discovered smatch matches: $(wc -l $SMATCH_OUTPUT)"

	# search unknown callers...not really working yet..
	#$BKC_ROOT/kafl/trace_callers.py $WORK_DIR > $WORK_DIR/traces/io_callers.lst
}

ACTION="$1"
shift || fatal "Missing argument: <cmd>"

[ "$ACTION" == "help" ] && usage
[ "$ACTION" == "--help" ] && usage
[ "$ACTION" == "-h" ] && usage


TARGET_ROOT="$(realpath $1)"
shift || fatal "Missing argument: <dir>"

test -d "$BKC_ROOT" || fatal "Could not find BKC_ROOT. Check set_env.sh."
test -d "$KAFL_ROOT" || fatal "Could not find KAFL_ROOT. Check set_env.sh."


# check if TARGET_ROOT is a valid <target> or <workdir>
if [ -f $TARGET_ROOT/bzImage ]; then
	TARGET_BIN=$TARGET_ROOT/bzImage
	TARGET_MAP=$TARGET_ROOT/System.map
	TARGET_ELF=$TARGET_ROOT/vmlinux
	WORK_DIR=$DEFAULT_WORK_DIR
elif [ -f $TARGET_ROOT/arch/x86/boot/bzImage ]; then
	TARGET_BIN=$TARGET_ROOT/arch/x86/boot/bzImage
	TARGET_MAP=$TARGET_ROOT/System.map
	TARGET_ELF=$TARGET_ROOT/vmlinux
	WORK_DIR=$DEFAULT_WORK_DIR
elif [ -f $TARGET_ROOT/target/bzImage ]; then
	TARGET_BIN=$TARGET_ROOT/target/bzImage
	TARGET_MAP=$TARGET_ROOT/target/System.map
	TARGET_ELF=$TARGET_ROOT/target/vmlinux
	WORK_DIR=$TARGET_ROOT
fi

test -d "$TARGET_ROOT" || fatal "Invalid folder $TARGET_ROOT"
test -f "$TARGET_BIN" || fatal "Could not find bzImage in $TARGET_ROOT or $TARGET_ROOT/target/"
test -f "$TARGET_ELF" || fatal "Could not find vmlinux in $TARGET_ROOT or $TARGET_ROOT/target/"
test -f "$TARGET_MAP" || fatal "Could not find System.map in $TARGET_ROOT or $TARGET_ROOT/target/"

test -d $SHARE_DIR || mkdir -p $SHARE_DIR

case $ACTION in
	"full")
		KAFL_OPTS=$KAFL_FULL_OPTS
		run $*
		;;
	"run")
		KAFL_OPTS=$KAFL_QUICK_OPTS
		run $*
		;;
	"single")
		single $*
		echo
		;;
	"debug")
		debug $*
		echo
		;;
	"cov")
		cov $*
		;;
	"smatch")
		smatch $*
		;;
	"noise")
		noise $*
		echo
		;;
	"ranges")
		get_ip_regions
		echo "PT trace regions:"
		echo -e "\tip0: $ip0_a-$ip0_b"
		echo -e "\tip1: $ip1_a-$ip1_b"
		;;
	*)
		fatal "Unrecognized command $ACTION"
		;;
esac
