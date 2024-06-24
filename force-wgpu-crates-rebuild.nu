let files = [
	obj-x86_64-pc-windows-msvc\x86_64-pc-windows-msvc\debug\build\wgpu-*\
	obj-x86_64-pc-windows-msvc\x86_64-pc-windows-msvc\debug\deps\wgpu_*
	obj-x86_64-pc-windows-msvc\gfx\wgpu_bindings\
	obj-x86_64-pc-windows-msvc\toolkit\library\build\xul.dll
	obj-x86_64-pc-windows-msvc\toolkit\library\build\xul.dll
	obj-x86_64-pc-windows-msvc\dist\bin\xul.dll
]
rm -rf ...$files
nu ../scripts/fx-clobbuild.nu
