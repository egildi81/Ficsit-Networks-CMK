local id = component.findComponent("Computuer")[1]

if id then
	local server = component.proxy(id)
	print("OK : Computer trouvé")
else
	print("NOK: Computer non trouvé")
end