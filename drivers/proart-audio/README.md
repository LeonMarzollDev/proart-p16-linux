# proart_audio

Gives the two Cirrus Logic CS35L56 speaker amplifiers (SoundWire `sdw:0:1:01fa:3556:01:{0,1}`) of the
ASUS ProArt P16 H7607BA the device property `cirrus,firmware-uid = "10431484"`.

The cs35l56 driver names its tuning files after the sound card's PCI SSID or that property. The
MT8901 SoundWire machine driver sets no SSID and the ACPI tables carry no firmware UID, so the amps
only look for generic files and run on their ROM defaults (`FIRMWARE_MISSING`, "Calibration
disabled"). With the UID they load `cirrus/cs35l56-b0-dsp1-misc-10431484-spkid<N>.wmfw` and the
per-amp tunings `...-l1u0.bin` (left woofer) / `...-l1u1.bin` (right woofer).

The property is attached as a managed software node before the cs35l56 driver binds: the module is
a softdep of `snd_soc_cs35l56_sdw`, handles already-enumerated peripherals and registers a SoundWire
bus notifier for later ones. It only loads on DMI vendor `ASUS` / board `H7607BA`.

Install: `install/03-audio.sh` (DKMS + firmware from the ASUS Windows driver). License: GPL-2.0.
