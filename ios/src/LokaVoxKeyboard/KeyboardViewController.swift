import UIKit

class KeyboardViewController: UIInputViewController {

    private let placeholderLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()

        placeholderLabel.text = "LokaVox — skeleton (step 1)"
        placeholderLabel.font = .preferredFont(forTextStyle: .footnote)
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.textAlignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 260)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
    }

    override func textWillChange(_ textInput: UITextInput?) {}
    override func textDidChange(_ textInput: UITextInput?) {}
}
