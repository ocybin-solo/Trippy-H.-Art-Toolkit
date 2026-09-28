Closed Beta or PC (windows) beta README (readable inside APP, select "⚙️" then "HELP")


**T.H.A.T.** What is it?  [Trippy H. Art Toolkit]
* A open source shader sandbox that lets users design and save combinations of patterns & effects
* It has several animated patterns, and several effects, and a few crappy post process effect (hey it's a work in progress)')
* Recently added : complex math shaders - navigate weird space and accidentally unfold virtual reality
* Lets you save your work as a "preset"
* Lets you design transitions between presets, called "transition presets"
* Lets you watch a screensaver that you created


**BASIC CONTROLS**

* ← & → = modifies values inside a menu row
* ↑ & ↓ = scroll through menu lists
* ✔️= Confirms a menu selection
* ❌= Cancels or returns from a menu
* 💠= Opens the Lab or the Transition Lab (where we customize the pattern, or transition style)
* ⚙️= Opens the Main Menu (Contains "screensaver dev" mode toggle, a help menu, a controller layout menu, and a colors menu for choosing background/button color")
* 🙉= Hides an open menu, keeping it's place
* LMB or Touch + drag = PAN base layer (pass 1)
* RMB or 2 finger twist = Rotate the base layer
* Scroll wheel or 2 finger pinch = Zoom's the base layer 

 
**KEY INFORMATION**

* In the 💠 "Lab", you can only choose ONE basic pattern (pass 1), and ONE filter (pass 3)
* You can choose any number of EFFECTS (pass 2), and they stack on top of one another, in the order that you stack them.
* You can customize your button layout, button grid size, shader size, background colors, etc (in the app config menu, controller config)


**ADVANCED CONTROLS**

* Save a pattern preset = Customize a pattern and add effects, then Open ⚙️ and select "presets", then click SAVE
* Create a transition preset =
	
	1) Open ⚙️ and toggle "screensaver dev mode" ON 
	2) Exit the main menu and push 💠 to open "transition lab"
	3) Select & Configure the formula(s) then exit the menu
	
* When in Screensaver Dev Mode, additional controls are active:
	
	a) ← & → will transition between pattern presets (you must have at least two saved)
	b) ↑ & ↓ will increase/decrease the duration of the transition (this duration will be saved, it is unique to each transition you create)
	c) ✔️ button will offer open the SAVE menu for transitions
	d) To load a saved transition, open 💠 and scroll to the bottom to find the option "LOAD TRANSITION"
		
* Once you have saved a transition you can enable Screensaver Mode, which will automatically choose a random saved preset and a random saved transition



## License

This project is free software. It is licensed under the [GNU General Public License v3.0](LICENSE) or any later version.
### What you can do:
* **Run:** You can run the app for any purpose.
* **Study:** You can look at the source code to see how it works. (once released, find it on my git page here : https://github.com/ocybin-solo)
* **Modify:** You can change the code to add features or fix bugs.
* **Share:** You can make copies of the original or modified app and give them to others.
### The main rule (Copyleft):
* If you distribute your modified version of this app, you **must** also license it under the same GNU GPL terms. You must make your source code freely available to others as well. 
*(Note: While the original concept was inspired by an older project under the permissive MIT license (FREE SHADER APP, also on my GIT page), this entire codebase was written completely from scratch. This new version is fully bound by the terms of the GNU GPL.)*

## Authors & Acknowledgments

### Tools & Engine

Godot Engine  **  (https://godotengine.org/) (v4.7.2)  ** - This application was fully designed and built using the Godot Engine. Godot is free software distributed under the terms of the MIT License. See the official [Godot License Page](https://godotengine.org/license/) for full copyright notices and third-party components.

### AI Collaborators
This project was developed with the assistance of the following AI tools (free versions):
	
* Gemini AI - Assisted primarily with web research, documentation, and conceptual guidance.
* Claude AI - Assisted primarily with code debugging and refactoring major architectural changes.
* ChatGPT AI - Assisted with developing the shaders

While AI tools were used for research and code generation, all architectural decisions, final integrations, testing and review were performed by the primary author.

**Lead Author, Core Architect, and Developer** 
JEFF BOX / OCYBIN : on the web @ https://github.com/ocybin-solo
