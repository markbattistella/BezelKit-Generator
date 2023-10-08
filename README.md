<div align="center">

<img src="https://raw.githubusercontent.com/markbattistella/BezelKit/main/.github/data/kit-icon.png" width="128" height="128"/>

# BezelKit

<small>Perfecting Corners, One Radius at a Time</small>

![Languages](https://img.shields.io/badge/Languages-Javascript-white?labelColor=orange&style=flat)
![Platforms](https://img.shields.io/badge/Platforms-NodeJS-white?labelColor=gray&style=flat)
![Licence](https://img.shields.io/badge/Licence-MIT-white?labelColor=blue&style=flat)

</div>

## Overview

This is the command line generator for the [`BezelKit`](https://github.com/markbattistella/BezelKit) Swift package.

## Important

Running this script standalone **will** fail as it attempts to copy the `bezel.min.json` into the `/Resources` directory (which does not exist).

To use this repo script it is aimed to be run from the [`BezelKit`](https://github.com/markbattistella/BezelKit) repo directory.

## Generating New Bezels

You can generate new bezel data for additional devices using the `index.js` NodeJS script located in the `Generator` folder.

### Requirements

- iOS/iPadOS runtime installed on your macOS machine to get the simulator.
- NodeJS installed to run the script.
- All requirements for running a simulator, opening an Xcode project, etc.

**Recommendation**: Install it on a macOS VM so as not to interfere with your personal Xcode setup.

### Steps

All devices (pending, problematic, and completed) are stored within the `apple-device-database.json` file.

The file is sectioned into a few areas:

1. **devices**: These are the completed, and computed device identifiers and their names and bezel size. This is broken into three categories - `iPad`, `iPhone`, and `iPod`.

2. **pending**: The script uses the `pending` objects to decide which simulators to boot and fetch bezel sizes from. They are to be inserted as:

    ```json
    "pending" : {
      "identifier" : { "name" : "Simulator name" }
    }

    "pending" : {
      "iPhone16,2" : { "name" : "iPhone 15 Pro Max" }
    }
    ```

3. **Success & Failure**:
   - If the simulator lookup **succeeds**, the simulator data is moved to the `devices` object.
   - If the simulator lookup **fails**, the simulator identifier and object data is moved to the `problematic` object.

#### Running the script

```bash
cd ./Generator
node index.js
```

### Updating Data

If you'd like to update or extend the list of device bezel sizes, you can easily do so by:

1. **Adding to `pending` object**: Add more devices and their identifiers to the existing JSON file. Make sure the friendly names in the JSON match the "Device Type" from the `Create New Simulator` screen in Xcode.

   ![Add New Simulator](https://raw.githubusercontent.com/markbattistella/BezelKit/main/.github/data/simulator.jpg)

    ```json
    "pending" : {
      "iPhone8,1" : { "name" : "iPhone 6s" }
    }
    ```

2. **Problematic Simulators**: If any simulators are listed under the `problematic` key, they are automatically moved into pending the next time the script is run.

By following these steps, you can continually update and maintain the device bezel data.

Once the script completes and updates the `bezel.min.json` for the actual package, `pending` and `problematic` keys are deleted, and the JSON is minified.

## Contributing

Contributions are more than welcome. If you find a bug or have an idea for an enhancement, please open an issue or provide a pull request.

Please follow the code style present in the current code base when making contributions.

**Note**: any pull requests need to have the title in the following format, otherwise it will be rejected.

```text
YYYY-mm-dd - {title}
eg. 2023-08-24 - Updated README file
```

I like to track the day from logged request to completion, allowing sorting, and extraction of data. It helps me know how long things have been pending and provides OCD structure.

## Licence

The BezelKit package is released under the MIT licence. See [LICENCE](https://github.com/markbattistella/BezelKit-Generator/blob/main/LICENCE) for more information.
