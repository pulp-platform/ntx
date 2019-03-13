# Copyright 2017-2019 ETH Zurich and University of Bologna.
#
# Copyright and related rights are licensed under the Solderpad Hardware
# License, Version 0.51 (the "License"); you may not use this file except in
# compliance with the License.  You may obtain a copy of the License at
# http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
# or agreed to in writing, software, hardware and materials distributed under
# this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
# CONDITIONS OF ANY KIND, either express or implied. See the License for the
# specific language governing permissions and limitations under the License.
#
# Michael Schaffner (schaffner@iis.ee.ethz.ch)
# Fabian Schuiki (fschuiki@iis.ee.ethz.ch)

APIDIR ?= ../api
CXXFLAGS ?= -O3 -Wall -std=c++11 -static-libstdc++ -static-libgcc -I$(APIDIR)

all:: genTestData

genTestData: genTestData.cpp $(APIDIR)/fp32_mac.cpp $(APIDIR)/ntx_api.cpp
	$(CXX) $(CXXFLAGS) -o $@ $^

stimuli: genTestData
	mkdir -p data
	./genTestData data
