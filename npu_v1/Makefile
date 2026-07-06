#-------------------------------------------------------------------------------------------------------
all: \
		vcs \
		verdi

#-------------------------------------------------------------------------------------------------------
# VCS
vcs   :
	vcs  \
		-f files.f \
		-timescale=1ns/1ns \
		-full64  -R  +vc  +v2k  -sverilog  -debug_access+all  \
		|tee vcs.log  
#-------------------------------------------------------------------------------------------------------
# irun

irun:
	irun \
		+sv -disable_sem2009  +nc64bit -access +rwc +nctimescale+1ns/1ps -loadpli1 debpli:novas_pli_boot -f files.f -l irun.log

#-------------------------------------------------------------------------------------------------------
# questasim

questasim: com sim
com:
	vlib work 
	vmap work work
	vlog -64 -sv +acc \
	-f files.f \
	-l com_questa.log

sim:
	vsim \
		-64 -batch -pli $(VERDI_HOME)/share/PLI/MODELSIM/linux64/novas_fli.so \
		-t 1ns \
		work.tb \
		-do "run -all"

#-------------------------------------------------------------------------------------------------------
# verdi

verdi  :
	verdi -sv -f files.f -ssf tb.fsdb &

#-------------------------------------------------------------------------------------------------------
clean  :
	 rm  -rf  *~  core  csrc  simv*  vc_hdrs.h  ucli.key  urg* *.log  novas.* *.fsdb* verdiLog  64* DVEfiles *.vpd
	 rm -rf INCA_libs irun*
	 rm -rf modelsim.ini transcript work
