# Contributing

## Start Writing Code

The best contribution you can make is to provide your code to the project.

You can make small fixes, improvements, or propose your solutions to specific issues in the system’s code.

But if you are deeply interested in OS development, you can also participate in the development of various kernel subsystems, its core components, architecture, and of course, device drivers!

For more details, familiarize yourself with the source code and OS structure by referring to the [documentation](./README.md#documentation).

Also see: [**Where to start?**](#where-to-start)

## Documentation

Writing documentation is also a crucial aspect of OS development.

If you have the skills to read code and understand the kernel structure, you can help by adding to the code documentation. This can be done by writing `/// ...` comments in the code.

Document:
- functions,
- structures,
- individual components,
- individual files,
- and more...

You can also contribute to the [documentation book](https://github.com/bagggage/bamos-book). Document some OS features and
create an pull request with your changes.

## Testing

Security and stability are especially important in low-level software.

Try building and running the system in a virtual machine or even on real hardware. Test various hardware configurations and devices. Look for bugs, omissions, and other gaps in the kernel code.

Then create an issue with a **description** of the specific problem and include instructions on how to **reproduce** it. We would greatly appreciate it if you could also spend time finding and developing a suitable solution for the problem and propose it in your issue.

## Proposals

You can offer your ideas for improving the project.

The most needed contributions are solutions to various architectural issues, kernel design, user space, and other elements. If you have your own ideas or are willing to share your expertise on how certain things can be implemented within the OS, feel free to create an issue with your suggestion. Make sure to describe the background and justification for your proposed solution so that the maintainers and other community members can better understand and assess your idea.

## Where to start?

To begin, it’s best to clone the project, perform a [build from source](./README.md#building-from-source), and run the OS.

Next, familiarize yourself with the system’s code, its current stage of development, and other details.

Use the [documentation](./README.md#documentation) for a better understanding.

**Experiment**. Create a **fork** of the project and start making changes. Test your abilities, improve, fix, add something new, or modify the existing code to suit your style.

Then, if you find your changes successful, feel free to [**prepare**](#how-to-prepare-changes-for-merging) them and create a **pull request**. Explain the essence of your changes and improvements, and it will be reviewed as soon as possible.

### How to prepare changes for merging?

For your changes to be accepted, they must be rational and aimed at improving the project—enhancing its quality, stability, usability, or expanding functionality.

If it’s code, it should meet minimal quality standards:
- Follow the project’s coding style,
- Maintain the component hierarchy,
- Be *stable* and *optimized*.

The project is in an active development stage, so certain imperfections, errors, or incomplete code may be tolerated. However, as the project grows, the standards will become stricter.

In any case, we welcome any contribution!

---

Thank you for your support,  
**bagggage**.
