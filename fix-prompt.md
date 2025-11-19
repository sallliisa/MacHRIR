I’m building an HRIR-based binauralizer. Right now my code only takes the first two channels of the HRIR WAV (left-ear and right-ear impulse responses). I want to replace this with a proper multi-channel approach like HeSuVi. Read this carefully and then generate the correct channel-mapping and convolution design.

New requirements:
	1.	Support HRIR WAV files that contain many channels (e.g., 8, 16, 24, 50+ channels).
	2.	Channels represent virtual loudspeaker positions, not left/right ears.
	•	Example: L, R, C, LFE, SL, SR, RL, RR, TFL, TFR, etc.
	3.	Each virtual speaker position has TWO HRIRs:
	•	one HRIR channel for left ear
	•	one HRIR channel for right ear
	4.	I need a mapping stage that:
	•	reads the HRIR channel description (or receives a mapping table)
	•	maps every HRIR pair to a named virtual speaker position
	•	supports arbitrary layouts (4.0, 5.1, 7.1, 7.1.4, custom, etc.)
	5.	Then for audio processing:
	•	For each input channel (L/R for stereo, or 7.1, etc.), route it to the corresponding virtual speaker position.
	•	Convolve that input with the pair of HRIR channels (left-ear IR, right-ear IR).
	•	Sum all virtual speaker outputs into the final 2-channel binaural output.
	6.	This must allow custom mapping tables, similar to HeSuVi’s mix.txt:
	•	Example:
  ```
  L0 = LVI       ; Left virtual speaker → HRIR channel 0 (left ear)
R1 = LVI       ; Left virtual speaker → HRIR channel 1 (right ear)
SL0 = SLVI     ; Surround left virtual speaker → channels ...
...

	7.	Important:
	•	Do NOT assume “first 2 channels = left/right ear.”
	•	Do NOT ignore the extra HRIR channels.
	•	I want a framework where arbitrary HRIR channel counts can be used.
	•	The output must always be stereo, created by summing all convolved virtual speaker outputs.
	8.	The output of your answer must include:
	•	A complete architecture description
	•	The mapping algorithm
	•	How to index HRIR channels correctly
	•	How to handle arbitrary layouts
	•	A final formula/pseudocode for the mixing stage
	•	Clear examples for 5.1 and 7.1.4 HRIRs

Generate the design in a way that can be implemented in Swift/C++ for real-time convolution.