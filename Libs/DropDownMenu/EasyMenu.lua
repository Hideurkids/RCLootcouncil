
-- Simplified Menu Display System
--	This is a basic system for displaying a menu from a structure table.
--
--	See UIDropDownMenu.lua for the menuList details.
--
--	Args:
--		menuList - menu table
--		menuFrame - the UI frame to populate
--		anchor - where to anchor the frame (e.g. CURSOR)
--		x - x offset
--		y - y offset
--		displayMode - border type
--		autoHideDelay - how long until the menu disappears
--
--
function Lib_EasyMenu(menuList, menuFrame, anchor, x, y, displayMode, autoHideDelay )
	if ( displayMode == "MENU" ) then
		menuFrame.displayMode = displayMode;
	end
	Lib_UIDropDownMenu_Initialize(menuFrame, Lib_EasyMenu_Initialize, displayMode, nil, menuList);
	Lib_ToggleDropDownMenu(1, nil, menuFrame, anchor, x, y, menuList, nil, autoHideDelay);
end

function Lib_EasyMenu_Initialize( frame, level, menuList )
	local tgetn = table.getn -- Lua 5.0: no `#` operator, use table.getn(t)
	for index = 1, tgetn(menuList) do
		local value = menuList[index]
		if (value.text) then
			value.index = index;
			Lib_UIDropDownMenu_AddButton( value, level );
		end
	end
end

