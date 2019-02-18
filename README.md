# Network Training Accelerator

This is NTX, the Network Training Accelerator, an optimized streaming unit capable of performing high efficiency, single-cycle, 32 bit floating point multiply-accumulate operations on large batches of data. It is capable of autonomously fetching operands from an attached memory and storing the results back. Addresses are generated as linear combination of a configurable number of nested hardware loops.

Made with ❤️ at ETH Zurich. Created by Michael Schaffner and Fabian Schuiki.

## Usage

Refer to the `Bender.yml` file for the order in which the source files need to be compiled. NTX expects to be attached to a memory system via two ports, and would like to be configured via its staging area.

## License

NTX is released under the terms of the Solderpad Hardware Licence. See the attached [LICENSE] file for details.
