test:
	nvim --headless -u NONE -l test/run.lua $(FILTER)

.PHONY: test demo fuzz soak

demo:
	nvim -u demo/init.lua demo/notes.org

# Random Neovim edits and Emacs commands; both sides must keep the same text.
fuzz:
	nvim --headless -u NONE -l test/fuzz.lua $(SEED) $(STEPS)

# A long session over several files, agenda and capture; logs soak.tsv.
soak:
	nvim --headless -u NONE -l test/soak.lua $(SEED) $(STEPS)
