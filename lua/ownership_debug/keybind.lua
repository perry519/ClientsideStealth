local CST = _G.ClientsideStealth
if CST and ContourExt then
	CST.module("ownership_debug/hooks/contour"):install()
	CST.module("ownership_debug/init"):toggle()
end
